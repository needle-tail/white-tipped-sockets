//
//  main.swift
//
//
//  Created by Cole M on 6/22/22.
//


func main() async {
let server = WTNIOServer(port: 8888, host: "localhost")
await server.start()
}

#if swift(>=5.7)
await main()
#else
_runAsyncMain {
    await main()
}
#endif
