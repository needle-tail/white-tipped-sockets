//
//  WhiteTipped.swift
//  
//
//  Created by Cole M on 6/17/22.
//

import Foundation
import Network
import OSLog

extension WhiteTipped {
    func trustSelfSigned(_ queue: DispatchQueue, certificates: [String]?) throws -> NWParameters {
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
                        self.logger.critical("Trust failed: \(error.localizedDescription)")
                    }
                    self.logger.info("\(result)")
                    sec_protocol_verify_complete(result)
                }
            }, queue)
        
        
        /// We can set minimum TLS protocol
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        
        return NWParameters(tls: options)
    }
}
