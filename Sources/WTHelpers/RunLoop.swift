//
//  RunLoop.swift
//  
//
//  Created by Cole M on 4/17/22.
//

import Foundation

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class RunLoop {
    
    public enum LoopResult {
        case finished, runnning
    }
    
    /// This class method sets the date for the time interval to stop execution on
    /// - Parameter timeInterval: A Double Value in seconds
    /// - Returns: The Date for the exectution to stop on
    public class func timeInterval(_ timeInterval: TimeInterval) -> Date {
        let timeInterval = TimeInterval(timeInterval)
        let deadline = Date(timeIntervalSinceNow: Double(Double(1_000_000_000) * timeInterval) / Double(1_000_000_000)).timeIntervalSinceNow
        return Date(timeIntervalSinceNow: deadline)
    }
    
    ///  This method determines when the run loop should start and stop depending on the parameters value
    /// - Parameters:
    ///   - now: The Date we wish to start the execution at
    ///   - ack: The Acknowledgement we may receive from the server
    ///   - canRun: A Bool value we can customize property values in the caller
    /// - Returns: A Boolean value that indicates whether or not the loop should run
    public class func execute(_
                       now: Date,
                       canRun: Bool
    ) async -> Bool {
        
        func runTask() async -> LoopResult {
            let runningDate = Date()
            if canRun == true {
                return .runnning
            } else if now >= runningDate {
                return .finished
            } else {
                return .finished
            }
        }
        let result = await runTask()
        switch result {
        case .finished:
            return false
        case .runnning:
            return true
        }
    }
}
