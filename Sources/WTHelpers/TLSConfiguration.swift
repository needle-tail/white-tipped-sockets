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

public class TLSConfiguration{
    public static func trustSelfSigned(_
                                queue: DispatchQueue,
                                certificates: [String]?,
                                logger: Logger
    ) async throws -> NWParameters {
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
                    if let error = error {
                        logger.critical("Trust failed: \(error.localizedDescription)")
                    }
                    logger.info("Validation Result: \(result)")
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
