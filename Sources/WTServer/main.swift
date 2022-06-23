//
//  File.swift
//  
//
//  Created by Cole M on 6/20/22.
//

#if canImport(Network)
import Foundation

func main() async {
    let ws = await WhiteTippedServer(headers: nil, urlRequest: nil, cookies: nil)
    await ws.listen()
}


_runAsyncMain {
    await main()
    try? await Task.sleep(nanoseconds: 9000000000)
}

#endif
