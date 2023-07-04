//
//  WhiteTipped.swift
//  
//
//  Created by Cole M on 6/17/22.
//

#if canImport(Network)
import Foundation
import Network
import OSLog


@available(iOS 14, macOS 13, *)
fileprivate var _logger: [ObjectIdentifier: Logger] = [:]
@available(iOS 14, macOS 13, *)
extension TLSConfiguration {
    static var logger: Logger? {
        get { return _logger[ObjectIdentifier(self)] }
        set { _logger[ObjectIdentifier(self)] = newValue }
    }
}

fileprivate var _oslog: [ObjectIdentifier: OSLog] = [:]
extension TLSConfiguration {
static var oslog: OSLog? {
    get { return _oslog[ObjectIdentifier(self)] }
    set { _oslog[ObjectIdentifier(self)] = newValue }
}
}

public class TLSConfiguration{
    
    
    
    @available(iOS 13, *)
    public static func trustSelfSigned(_
                                queue: DispatchQueue,
                                certificates: [String]?
    ) throws -> NWParameters {
        
        if #available(iOS 14, macOS 13, *) {
            Self.logger = Logger(subsystem: "TLSConfiguration", category: "trustSelfSigned")
        } else {
            Self.oslog = OSLog(subsystem: "TLSConfiguration", category: "trustSelfSigned")
        }
        
        let options = NWProtocolTLS.Options()
        
        var secTrustRoots: [SecCertificate]?
        secTrustRoots = try certificates?.compactMap({ certificate in
            let filePath = Bundle.main.path(forResource: certificate, ofType: "der")!
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            return SecCertificateCreateWithData(nil, data as CFData)!
        })
        
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, sec_trust, sec_protocol_verify_complete in
                
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                if let trustRootCertificates = secTrustRoots {
                    SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                }
                dispatchPrecondition(condition: .onQueue(queue))
              
                    SecTrustEvaluateAsyncWithError(trust, queue) { _, result, error in
                        if #available(iOS 14, macOS 13, *) {
                        if let error = error {
                            logger?.critical("Trust failed: \(error.localizedDescription)")
                        }
                        logger?.info("Validation Result: \(result)")
                        } else {
                            if let error = error {
                                guard let oslog = oslog else { return }
                                os_log("Trust failed: %@", log: oslog, type: .default, error.localizedDescription)
                            }
                            guard let oslog = oslog else { return }
                            os_log("Validation Result: %@", log: oslog, type: .default, result)
                        }
                        sec_protocol_verify_complete(result)
                    }

                }, queue)

        
        /// We can set minimum TLS protocol
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        
        let parameters = NWParameters(tls: options)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }
}
#endif
