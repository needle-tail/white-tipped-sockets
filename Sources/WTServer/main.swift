//
//  File.swift
//  
//
//  Created by Cole M on 6/20/22.
//

#if canImport(Network)
import Foundation
import WhiteTippedListener

func main() async throws {
    if #available(iOS 15, macOS 12, *) {
        let ws = try await WhiteTippedListener(configuration: WhiteTippedListener.NetworkConfiguration(queue: "server"))
        await ws.listen()
    }
}

    try? await main()
    try? await Task.sleep(nanoseconds: 9000000000)
#endif
