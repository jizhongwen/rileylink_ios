//
//  OmnipodPumpManager.swift
//  OmniKit
//
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import HealthKit
import LoopKit
import RileyLinkKit
import RileyLinkBLEKit
import os.log

public enum ReservoirAlertState {
    case ok
    case lowReservoir
    case empty
}

public protocol PodStateObserver: class {
    func podStateDidUpdate(_ state: PodState?)
}

public enum OmnipodPumpManagerError: Error {
    case noPodPaired
    case podAlreadyPaired
    case podAlreadyPrimed
    case notReadyForPrime
    case notReadyForCannulaInsertion
}

extension OmnipodPumpManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("No pod paired", comment: "Error message shown when no pod is paired")
        case .podAlreadyPrimed:
            return LocalizedString("Pod already primed", comment: "Error message shown when prime is attempted, but pod is already primed")
        case .podAlreadyPaired:
            return LocalizedString("Pod already paired", comment: "Error message shown when user cannot pair because pod is already paired")
        case .notReadyForPrime:
            return LocalizedString("Pod is not in a state ready for priming.", comment: "Error message when prime fails because the pod is in an unexpected state")
        case .notReadyForCannulaInsertion:
            return LocalizedString("Pod is not in a state ready for cannula insertion.", comment: "Error message when cannula insertion fails because the pod is in an unexpected state")
        }
    }
    
    public var failureReason: String? {
        switch self {
        case .noPodPaired:
            return nil
        case .podAlreadyPrimed:
            return nil
        case .podAlreadyPaired:
            return nil
        case .notReadyForPrime:
            return nil
        case .notReadyForCannulaInsertion:
            return nil
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("Please pair a new pod", comment: "Recover suggestion shown when no pod is paired")
        case .podAlreadyPrimed:
            return nil
        case .podAlreadyPaired:
            return nil
        case .notReadyForPrime:
            return nil
        case .notReadyForCannulaInsertion:
            return nil
        }
    }
}


public class OmnipodPumpManager: RileyLinkPumpManager, PumpManager {

    public var pumpRecordsBasalProfileStartEvents = false
    
    public var pumpReservoirCapacity: Double {
        return Pod.reservoirCapacity
    }
    
    private var lastPumpDataReportDate: Date?
    
    // MARK: - PumpManagerStatusObserver
    private var statusObservers = WeakObserverSet<PumpManagerStatusObserver>()
    
    public func addStatusObserver(_ observer: PumpManagerStatusObserver) {
        queue.async {
            self.statusObservers.add(observer)
        }
    }
    
    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        queue.async {
            self.statusObservers.remove(observer)
        }
    }
    
    private func notifyStatusObservers() {
        let status = self.status
        pumpManagerDelegate?.pumpManager(self, didUpdate: status)
        for observer in statusObservers {
            observer.pumpManager(self, didUpdate: status)
        }
    }

    
    // MARK: - PodStateObserver
    private var podStateObservers = WeakObserverSet<PodStateObserver>()
    
    public func addPodStateObserver(_ observer: PodStateObserver) {
        queue.async {
            self.podStateObservers.add(observer)
        }
    }
    
    public func removePodStateObserver(_ observer: PodStateObserver) {
        queue.async {
            self.podStateObservers.remove(observer)
        }
    }
    
    private func notifyPodStateObservers() {
        let podState = self.state.podState
        for observer in podStateObservers {
            observer.podStateDidUpdate(podState)
        }
    }

    /// TODO: Isolate to queue
    private var isPumpDataStale: Bool {
        let pumpStatusAgeTolerance = TimeInterval(minutes: 6)
        let pumpDataAge = -(self.lastPumpDataReportDate ?? .distantPast).timeIntervalSinceNow
        return pumpDataAge > pumpStatusAgeTolerance
    }


    // MARK: PumpManager
    
    public func updateBLEHeartbeatPreference() {
        queue.async {
            /// Controls the management of the RileyLink timer tick, which is a reliably-changing BLE
            /// characteristic which can cause the app to wake. For most users, the G5 Transmitter and
            /// G4 Receiver are reliable as hearbeats, but users who find their resources extremely constrained
            /// due to greedy apps or older devices may choose to always enable the timer by always setting `true`
            self.rileyLinkDeviceProvider.timerTickEnabled = self.isPumpDataStale || (self.pumpManagerDelegate?.pumpManagerShouldProvideBLEHeartbeat(self) == true)
        }
    }
    
    public static let managerIdentifier: String = "Omnipod"
    
    public static func roundToDeliveryIncrement(units: Double) -> Double {
        return round(units * Pod.pulsesPerUnit) / Pod.pulsesPerUnit
    }
    
    public func roundToDeliveryIncrement(units: Double) -> Double {
        return OmnipodPumpManager.roundToDeliveryIncrement(units: units)
    }

    
    public init(state: OmnipodPumpManagerState, rileyLinkDeviceProvider: RileyLinkDeviceProvider, rileyLinkConnectionManager: RileyLinkConnectionManager? = nil) {
        self.state = state
        self.podComms = PodComms(podState: state.podState)
        super.init(rileyLinkDeviceProvider: rileyLinkDeviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)
        
        self.podComms.delegate = self
        self.podComms.messageLogger = self
    }
    
    public required convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = OmnipodPumpManagerState(rawValue: rawState),
            let connectionManagerState = state.rileyLinkConnectionManagerState else
        {
            return nil
        }
        
        let rileyLinkConnectionManager = RileyLinkConnectionManager(state: connectionManagerState)
        
        self.init(state: state, rileyLinkDeviceProvider: rileyLinkConnectionManager.deviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)
        
        rileyLinkConnectionManager.delegate = self
    }
    
    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }
    
    override public var rileyLinkConnectionManagerState: RileyLinkConnectionManagerState? {
        get {
            return state.rileyLinkConnectionManagerState
        }
        set {
            state.rileyLinkConnectionManagerState = newValue
        }
    }
    
    // TODO: apply lock
    public private(set) var state: OmnipodPumpManagerState {
        didSet {
            pumpManagerDelegate?.pumpManagerDidUpdateState(self)
            
            if oldValue.podState?.suspended != state.podState?.suspended ||
                oldValue.timeZone != state.timeZone
            {
                notifyStatusObservers()
            }
        }
    }
    
    private var device: HKDevice {
        if let podState = state.podState {
            return HKDevice(
                name: type(of: self).managerIdentifier,
                manufacturer: "Insulet",
                model: "Eros",
                hardwareVersion: nil,
                firmwareVersion: podState.piVersion,
                softwareVersion: String(OmniKitVersionNumber),
                localIdentifier: String(format:"%04X", podState.address),
                udiDeviceIdentifier: nil
            )
        } else {
            return HKDevice(
                name: type(of: self).managerIdentifier,
                manufacturer: "Insulet",
                model: "Eros",
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: String(OmniKitVersionNumber),
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
        }
    }
    
    private var basalDeliveryStateTransitioning: Bool = false {
        didSet {
            notifyStatusObservers()
        }
    }
    
    private var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        guard let podState = state.podState else {
            return .active
        }
        
        if basalDeliveryStateTransitioning {
            return podState.suspended ? .resuming : .suspending
        } else {
            return podState.suspended ? .suspended : .active
        }
    }
    
    private var bolusStateTransitioning: Bool = false {
        didSet {
            notifyStatusObservers()
        }
    }
    
    private var bolusState: PumpManagerStatus.BolusState {
        guard let podState = state.podState else {
            return .none
        }
        if let bolus = podState.unfinalizedBolus, bolus.finishTime.timeIntervalSinceNow < 0 {
            // TODO: return progress
            return bolusStateTransitioning ? .canceling : .inProgress(Float(bolus.progress))
        } else {
            return bolusStateTransitioning ? .initiating : .none
        }
    }
    
    public var status: PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.timeZone,
            device: device,
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState,
            bolusState: bolusState)
    }
   
    public var hasActivePod: Bool {
        return self.state.podState?.isActive == true
    }
    
    public weak var pumpManagerDelegate: PumpManagerDelegate?
    
    public let log = OSLog(category: "OmnipodPumpManager")
    
    public static let localizedTitle = LocalizedString("Omnipod", comment: "Generic title of the omnipod pump manager")
    
    public var localizedTitle: String {
        return String(format: LocalizedString("Omnipod", comment: "Omnipod title"))
    }
    
    override public func deviceTimerDidTick(_ device: RileyLinkDevice) {
        self.pumpManagerDelegate?.pumpManagerBLEHeartbeatDidFire(self)
    }
    
    // MARK: - CustomDebugStringConvertible
    
    override public var debugDescription: String {
        let lines = [
            "## OmnipodPumpManager",
            state.debugDescription,
            "",
            String(describing: podComms),
            super.debugDescription,
            "",
            ]

        return lines.joined(separator: "\n")
    }
    
    // MARK: - Pod comms
    private(set) var podComms: PodComms
    
    
    public func getPodState(completion: @escaping (PodState?) -> Void) {
        queue.async {
            completion(self.state.podState)
        }
    }
    
    public func primeFinishesAt(completion: @escaping (Date?) -> Void) {
        queue.async {
            completion(self.state.podState?.primeFinishTime)
        }
    }
    
    public func forgetPod() {
        queue.async {
            self.state.podState = nil
            self.podComms = PodComms(podState: nil)
            self.podComms.delegate = self
            self.podComms.messageLogger = self
            self.notifyPodStateObservers()
            self.state.messageLog.erase()
        }
    }
    
    // MARK: Testing
    private func jumpStartPod(address: UInt32, lot: UInt32, tid: UInt32, fault: PodInfoFaultEvent? = nil, startDate: Date? = nil, mockFault: Bool) {
        let start = startDate ?? Date()
        let expire = start.addingTimeInterval(.days(3))
        self.state.podState = PodState(address: address, activatedAt: start, expiresAt: expire, piVersion: "jumpstarted", pmVersion: "jumpstarted", lot: lot, tid: tid)
        self.state.podState?.setupProgress = .podConfigured
        
        let fault = mockFault ? try? PodInfoFaultEvent(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!) : nil
        self.state.podState?.fault = fault
        self.podComms = PodComms(podState: state.podState)
        self.notifyPodStateObservers()
    }
    
    // MARK: - Pairing
    public func pairAndPrime(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {
        
        #if targetEnvironment(simulator)
        // If we're in the simulator, create a mock PodState
        let mockFaultDuringPairing = false
        queue.asyncAfter(deadline: .now() + .seconds(2)) {
            self.jumpStartPod(address: 0x1f0b3557, lot: 40505, tid: 6439, mockFault: mockFaultDuringPairing)
            self.state.podState?.setupProgress = .priming
            self.notifyPodStateObservers()
            if mockFaultDuringPairing {
                completion(.failure(PodCommsError.podFault(fault: self.state.podState!.fault!)))
            } else {
                let mockPrimeDuration = TimeInterval(.seconds(3))
                completion(.success(mockPrimeDuration))
            }
        }
        #else
        
        queue.async {
            
            if let podState = self.state.podState, !podState.setupProgress.primingNeeded {
                completion(.failure(OmnipodPumpManagerError.podAlreadyPrimed))
                return
            }
            
            let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            
            let semaphore = DispatchSemaphore(value: 0)
            var pairError: Error? = nil
            
            // If no pod state, or still need configuring, run pair()
            if self.state.podState == nil || self.state.podState?.setupProgress == .addressAssigned {
                self.podComms.pair(using: deviceSelector, timeZone: .currentFixed, messageLogger: self) { (error) in
                    pairError = error
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
            semaphore.wait()
            
            if let pairError = pairError {
                completion(.failure(pairError))
                return
            }
            
            self.podComms.runSession(withName: "Configure and prime pod", using: deviceSelector) { (result) in
                switch result {
                case .success(let session):
                    do {
                        let primeFinishedAt = try session.prime()
                        completion(.success(primeFinishedAt))
                    } catch let error {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
        #endif
    }
        
    public func insertCannula(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {
        #if targetEnvironment(simulator)
        let mockDelay = TimeInterval(seconds: 3)
        queue.asyncAfter(deadline: .now() + mockDelay) {

            // Mock fault
//            let fault = try! PodInfoFaultEvent(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!)
//            self.state.podState?.fault = fault
//            completion(.failure(PodCommsError.podFault(fault: fault)))
            
            // Mock success
            self.state.podState?.setupProgress = .completed
            self.notifyPodStateObservers()
            completion(.success(mockDelay))
        }
        #else
        
        queue.async {
            
            guard let podState = self.state.podState, podState.readyForCannulaInsertion else
            {
                completion(.failure(OmnipodPumpManagerError.notReadyForCannulaInsertion))
                return
            }
            
            guard podState.setupProgress.needsCannulaInsertion else {
                completion(.failure(OmnipodPumpManagerError.podAlreadyPaired))
                return
            }
            
            let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            let timeZone = self.state.timeZone
            
            self.podComms.runSession(withName: "Insert cannula", using: deviceSelector) { (result) in
                switch result {
                case .success(let session):
                    do {
                        
                        if podState.setupProgress.needsInitialBasalSchedule {
                            let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                            try session.programInitialBasalSchedule(self.state.basalSchedule, scheduleOffset: scheduleOffset)
                        }

                        let finishWait = try session.insertCannula()

                        self.queue.asyncAfter(deadline: .now() + finishWait) {
                            self.checkCannulaInsertionFinished()
                        }
                        completion(.success(finishWait))
                    } catch let error {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
        #endif
    }

    public func checkCannulaInsertionFinished() {
        queue.async {
            let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Check cannula insertion finished", using: deviceSelector) { (result) in
                switch result {
                case .success(let session):
                    do {
                        try session.checkInsertionCompleted()
                    } catch let error {
                        self.log.error("Failed to fetch pump status: %{public}@", String(describing: error))
                    }
                case .failure(let error):
                    self.log.error("Failed to fetch pump status: %{public}@", String(describing: error))
                }
            }
        }
    }

    public func assertCurrentPumpData() {

        queue.async {
            guard self.hasActivePod else {
                return
            }

            let recommendLoop = {
                self.log.info("Recommending Loop")
                self.pumpManagerDelegate?.pumpManagerRecommendsLoop(self)
            }

            if self.isPumpDataStale {
                self.log.info("Fetching status because pumpData is too old")
                self.getPodStatus(podComms: self.podComms) { (response) in
                    if case .success = response {
                        recommendLoop()
                    }
                }
            }
            
            guard !self.isPumpDataStale else {
                self.log.info("Not recommending Loop because pump data is stale")
                return
            }

            recommendLoop()
        }
    }
    
    public func refreshStatus(completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        queue.async {
            guard self.hasActivePod else {
                completion?(.failure(OmnipodPumpManagerError.noPodPaired))
                return
            }
            
            self.getPodStatus(podComms: self.podComms, completion: completion)
        }
    }

    // MARK: - Pump Commands

    // PumpManager queue only
    private func getPodStatus(podComms: PodComms, completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        
        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Get pod status", using: rileyLinkSelector) { (result) in
            do {
                switch result {
                case .success(let session):
                    let status = try session.getStatus()
                    
                    session.storeFinalizedDoses() { (doses) -> Bool in
                        return self.store(doses: doses)
                    }

                    if let reservoirLevel = status.reservoirLevel {
                        let semaphore = DispatchSemaphore(value: 0)
                        self.pumpManagerDelegate?.pumpManager(self, didReadReservoirValue: reservoirLevel, at: Date()) { (_) in
                            semaphore.signal()
                        }
                        semaphore.wait()
                    }
                    completion?(.success(status))
                case .failure(let error):
                    throw error
                }
            } catch let error {
                completion?(.failure(error))
                self.log.error("Failed to fetch pump status: %{public}@", String(describing: error))
            }
        }
    }
    
    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.hasActivePod else {
                completion(OmnipodPumpManagerError.noPodPaired)
                return
            }
            
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Suspend", using: rileyLinkSelector) { (result) in
                
                let session: PodCommsSession
                switch result {
                case .success(let s):
                    session = s
                case .failure(let error):
                    completion(error)
                    return
                }
                
                defer { self.basalDeliveryStateTransitioning = false }
                self.basalDeliveryStateTransitioning = true

                do {
                    let _ = try session.cancelDelivery(deliveryType: .all, beepType: .noBeep)
                    completion(nil)
                    
                    session.storeFinalizedDoses() { (doses) -> Bool in
                        return self.store(doses: doses)
                    }

                } catch (let error) {
                    completion(error)
                }
            }
        }
    }
    
    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.hasActivePod else {
                completion(OmnipodPumpManagerError.noPodPaired)
                return
            }
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Resume", using: rileyLinkSelector) { (result) in
                
                let session: PodCommsSession
                switch result {
                case .success(let s):
                    session = s
                case .failure(let error):
                    completion(error)
                    return
                }
                
                defer { self.basalDeliveryStateTransitioning = false }
                self.basalDeliveryStateTransitioning = true
                
                do {
                    let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                    let _ = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset)
                    completion(nil)
                } catch (let error) {
                    completion(error)
                }
            }
        }
    }
    
    
    public func acknowledgeAlerts(_ alertsToAcknowledge: AlertSet, completion: @escaping (_ alerts: [AlertSlot: PodAlert]?) -> Void) {
        queue.async {
            guard self.hasActivePod else {
                completion(nil)
                return
            }
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Acknowledge Alarms", using: rileyLinkSelector) { (result) in
                let session: PodCommsSession
                switch result {
                case .success(let s):
                    session = s
                case .failure:
                    completion(nil)
                    return
                }
                
                do {
                    let alerts = try session.acknowledgeAlerts(alerts: alertsToAcknowledge)
                    completion(alerts)
                } catch {
                    completion(nil)
                }
            }
        }
    }

    public func enactBolus(units: Double, at startDate: Date, willRequest: @escaping (DoseEntry) -> Void, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        queue.async {
            guard self.hasActivePod else {
                completion(.failure(SetBolusError.certain(OmnipodPumpManagerError.noPodPaired)))
                return
            }

            // Round to nearest supported volume
            let enactUnits = OmnipodPumpManager.roundToDeliveryIncrement(units: units)
            
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Bolus", using: rileyLinkSelector) { (result) in
                
                let session: PodCommsSession
                switch result {
                case .success(let s):
                    session = s
                case .failure(let error):
                    completion(.failure(SetBolusError.certain(error)))
                    return
                }
                
                var podStatus: StatusResponse
                
                do {
                    podStatus = try session.getStatus()
                } catch let error {
                    completion(.failure(SetBolusError.certain(error as? PodCommsError ?? PodCommsError.commsError(error: error))))
                    return
                }
                
                // If pod suspended, resume basal before bolusing
                if podStatus.deliveryStatus == .suspended {
                    do {
                        let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                        podStatus = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset)
                    } catch let error {
                        completion(.failure(SetBolusError.certain(error as? PodCommsError ?? PodCommsError.commsError(error: error))))
                        return
                    }
                    self.notifyStatusObservers()
                }
                
                guard !podStatus.deliveryStatus.bolusing else {
                    completion(.failure(SetBolusError.certain(PodCommsError.unfinalizedBolus)))
                    return
                }
                
                defer { self.bolusStateTransitioning = false }
                self.bolusStateTransitioning = true
                
                let date = Date()
                let endDate = date.addingTimeInterval(enactUnits / Pod.bolusDeliveryRate)
                let dose = DoseEntry(type: .bolus, startDate: date, endDate: endDate, value: enactUnits, unit: .units)
                willRequest(dose)
                
                let result = session.bolus(units: enactUnits)
                
                switch result {
                case .success:
                    completion(.success(dose))
                case .certainFailure(let error):
                    completion(.failure(SetBolusError.certain(error)))
                case .uncertainFailure(let error):
                    completion(.failure(SetBolusError.uncertain(error)))
                }
            }
        }
    }
    
    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        queue.async {
            guard let podState = self.state.podState, self.hasActivePod else {
                completion(.failure(OmnipodPumpManagerError.noPodPaired))
                return
            }

            // Round to nearest supported rate
            let rate = OmnipodPumpManager.roundToDeliveryIncrement(units: unitsPerHour)
            
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Enact Temp Basal", using: rileyLinkSelector) { (result) in
                self.log.info("Enact temp basal %.03fU/hr for %ds", rate, Int(duration))
                let session: PodCommsSession
                switch result {
                case .success(let s):
                    session = s
                case .failure(let error):
                    completion(.failure(error))
                    return
                }
                
                do {
                    guard !podState.suspended else {
                        self.log.info("Canceling temp basal because podState indicates pod is suspended.")
                        throw PodCommsError.podSuspended
                    }
                    
                    let status = try session.cancelDelivery(deliveryType: .tempBasal, beepType: .noBeep)

                    guard !status.deliveryStatus.bolusing else {
                        throw PodCommsError.unfinalizedBolus
                    }

                    guard status.deliveryStatus != .suspended else {
                        self.log.info("Canceling temp basal because status return indicates pod is suspended.")
                        throw PodCommsError.podSuspended
                    }

                    session.storeFinalizedDoses() { (doses) -> Bool in
                        return self.store(doses: doses)
                    }

                    if duration < .ulpOfOne {
                        // 0 duration temp basals are used to cancel any existing temp basal
                        let cancelTime = Date()
                        let dose = DoseEntry(type: .basal, startDate: cancelTime, endDate: cancelTime, value: 0, unit: .unitsPerHour)
                        completion(.success(dose))
                    } else {
                        let result = session.setTempBasal(rate: rate, duration: duration, confidenceReminder: false, programReminderInterval: 0)
                        let basalStart = Date()
                        let dose = DoseEntry(type: .basal, startDate: basalStart, endDate: basalStart.addingTimeInterval(duration), value: rate, unit: .unitsPerHour)
                        switch result {
                        case .success:
                            completion(.success(dose))
                        case .uncertainFailure(let error):
                            self.log.error("Temp basal uncertain error: %@", String(describing: error))
                            completion(.success(dose))
                        case .certainFailure(let error):
                            completion(.failure(error))
                        }
                    }
                } catch let error {
                    self.log.error("Error during temp basal: %@", String(describing: error))
                    completion(.failure(error))
                }
            }
        }
    }
    
    public func setTime(completion: @escaping (Error?) -> Void) {
        
        let timeZone = TimeZone.currentFixed
        
        queue.async {
            guard self.hasActivePod else {
                completion(OmnipodPumpManagerError.noPodPaired)
                return
            }

            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Set time zone", using: rileyLinkSelector) { (result) in
                switch result {
                case .success(let session):
                    do {
                        let _ = try session.setTime(timeZone: timeZone, basalSchedule: self.state.basalSchedule, date: Date())
                        self.state.timeZone = timeZone
                        completion(nil)
                    } catch let error {
                        completion(error)
                    }
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }

    public func setBasalSchedule(_ schedule: BasalSchedule, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.hasActivePod else {
                self.state.basalSchedule = schedule
                completion(nil)
                return
            }

            let timeZone = self.state.timeZone
            
            self.podComms.runSession(withName: "Save Basal Profile", using: self.rileyLinkDeviceProvider.firstConnectedDevice) { (result) in
                do {
                    switch result {
                    case .success(let session):
                        let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                        let _ = try session.cancelDelivery(deliveryType: .all, beepType: .noBeep)
                        let _ = try session.setBasalSchedule(schedule: schedule, scheduleOffset: scheduleOffset, confidenceReminder: false, programReminderInterval: 0)
                        self.state.basalSchedule = schedule
                        completion(nil)
                    case .failure(let error):
                        throw error
                    }
                } catch let error {
                    self.log.error("Save basal profile failed: %{public}@", String(describing: error))
                    completion(error)
                }
            }
        }
    }

    public func deactivatePod(completion: @escaping (Error?) -> Void) {
        #if targetEnvironment(simulator)
        queue.asyncAfter(deadline: .now() + .seconds(2)) {
            completion(nil)
        }
        #else
        queue.async {
            guard self.state.podState != nil else {
                completion(OmnipodPumpManagerError.noPodPaired)
                return
            }
            
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Deactivate pod", using: rileyLinkSelector) { (result) in
                switch result {
                case .success(let session):
                    do {
                        try session.deactivatePod()
                        completion(nil)
                    } catch let error {
                        completion(error)
                    }
                case .failure(let error):
                    completion(error)
                }
            }
        }
        #endif
    }

    public func testingCommands(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.hasActivePod else {
                completion(OmnipodPumpManagerError.noPodPaired)
                return
            }
            
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Testing Commands", using: rileyLinkSelector) { (result) in
                switch result {
                case .success(let session):
                    do {
                        let _ = try session.testingCommands()
                        completion(nil)
                    } catch let error {
                        completion(error)
                    }
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }
}

// MARK: -

extension OmnipodPumpManager: MessageLogger {
    func didSend(_ message: Data) {
        state.messageLog.record(MessageLogEntry(messageDirection: .send, timestamp: Date(), data: message))
    }
    
    func didReceive(_ message: Data) {
        state.messageLog.record(MessageLogEntry(messageDirection: .receive, timestamp: Date(), data: message))
    }
}

extension OmnipodPumpManager: PodCommsDelegate {
    
    public func store(doses: [UnfinalizedDose]) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        self.pumpManagerDelegate?.pumpManager(self, didReadPumpEvents: doses.map { NewPumpEvent($0) }, completion: { (error) in
            if let error = error {
                self.log.error("Error storing pod events: %@", String(describing: error))
            } else {
                self.log.error("Stored pod events: %@", String(describing: doses))
            }
            success = error == nil
            semaphore.signal()
        })
        semaphore.wait()
        
        if success {
            self.lastPumpDataReportDate = Date()
        }
        return success
    }
    
    func podComms(_ podComms: PodComms, didChange podState: PodState) {
        self.state.podState = podState
        notifyPodStateObservers()
    }
}

