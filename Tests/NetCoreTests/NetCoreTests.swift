import XCTest
@testable import NetCore

final class ParserTests: XCTestCase {
    func testPingParser() {
        let out = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms
        64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=14.100 ms
        Request timeout for icmp_seq 2
        64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=13.000 ms

        --- 1.1.1.1 ping statistics ---
        4 packets transmitted, 3 packets received, 25.0% packet loss
        round-trip min/avg/max/stddev = 12.345/13.148/14.100/0.724 ms
        """
        let r = PingParser.parse(out)
        XCTAssertEqual(r?.sent, 4)
        XCTAssertEqual(r?.received, 3)
        XCTAssertEqual(r?.samples, [12.345, 14.1, 13.0])
        XCTAssertEqual(r?.lossPercent ?? 0, 25, accuracy: 0.01)
        XCTAssertEqual(r?.median ?? 0, 13.0, accuracy: 0.001)
        XCTAssertEqual(r?.jitter ?? 0, (1.755 + 1.1) / 2, accuracy: 0.001)
    }

    func testPingAllLost() {
        let out = """
        --- 10.0.0.1 ping statistics ---
        5 packets transmitted, 0 packets received, 100.0% packet loss
        """
        let r = PingParser.parse(out)
        XCTAssertEqual(r?.lossPercent, 100)
        XCTAssertNil(r?.median)
    }

    func testRouteParser() {
        let out = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        let r = RouteParser.parse(out)
        XCTAssertEqual(r.gateway, "192.168.1.1")
        XCTAssertEqual(r.interface, "en0")
    }

    func testNetworkServices() {
        let out = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en7)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (*) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """
        let s = NetworkSetupParser.services(out)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[1], NetworkService(name: "Wi-Fi", hardwarePort: "Wi-Fi", device: "en0", enabled: true))
        XCTAssertEqual(s[0].name, "USB 10/100/1000 LAN")
        XCTAssertFalse(s[2].enabled)
    }

    func testDNSServers() {
        XCTAssertEqual(NetworkSetupParser.dnsServers("There aren't any DNS Servers set on Wi-Fi.\n"), [])
        XCTAssertEqual(NetworkSetupParser.dnsServers("1.1.1.1\n1.0.0.1\n2606:4700:4700::1111\n"),
                       ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111"])
        let scutil = """
        DNS configuration

        resolver #1
          nameserver[0] : 192.168.1.1
          nameserver[1] : 8.8.8.8
          if_index : 6 (en0)

        resolver #2
          domain   : local
          nameserver[0] : 192.168.1.1
        """
        XCTAssertEqual(NetworkSetupParser.scutilNameservers(scutil), ["192.168.1.1", "8.8.8.8"])
    }

    func testTrace() {
        let t = TraceParser.parse("fl=1\nh=speed.cloudflare.com\nip=103.1.2.3\nts=1\ncolo=SIN\nloc=ID\n")
        XCTAssertEqual(t, TraceInfo(ip: "103.1.2.3", colo: "SIN", location: "ID"))
    }
}

final class DNSPacketTests: XCTestCase {
    func testQueryEncoding() {
        let q = DNSPacket.query(id: 0xABCD, name: "google.com")
        XCTAssertEqual(Array(q.prefix(4)), [0xAB, 0xCD, 0x01, 0x00])
        XCTAssertEqual(Array(q[12..<24]), [6] + Array("google".utf8) + [3] + Array("com".utf8) + [0])
        XCTAssertEqual(Array(q.suffix(4)), [0, 1, 0, 1])
        XCTAssertEqual(q.count, 12 + 12 + 4)
    }

    func testReplyHeader() {
        var reply = Data([0xAB, 0xCD, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0])
        XCTAssertTrue(DNSPacket.isUsableReply(reply, expectedID: 0xABCD))
        XCTAssertFalse(DNSPacket.isUsableReply(reply, expectedID: 0x1234))
        XCTAssertEqual(DNSPacket.parseHeader(reply)?.answerCount, 2)
        reply[3] = 0x82 // SERVFAIL
        XCTAssertFalse(DNSPacket.isUsableReply(reply, expectedID: 0xABCD))
        reply[3] = 0x83 // NXDOMAIN still means the server answered
        XCTAssertTrue(DNSPacket.isUsableReply(reply, expectedID: 0xABCD))
    }
}

final class ChannelAdvisorTests: XCTestCase {
    func net(_ ch: Int, _ rssi: Int, _ band: WiFiBand = .ghz2, width: Int = 20) -> ObservedNetwork {
        ObservedNetwork(ssid: "n\(ch)", channel: ch, band: band, widthMHz: width, rssi: rssi)
    }

    func testRecommendsQuietest24() {
        let nets = [net(6, -50), net(6, -55), net(5, -60), net(1, -70), net(11, -85), net(6, -45)]
        let a = ChannelAdvisor.advise(band: .ghz2, networks: nets, currentChannel: 6, ownRSSI: -45)
        XCTAssertEqual(a.recommended, 11)
        XCTAssertTrue(a.shouldSwitch)
        XCTAssertEqual(a.otherNetworks, 5) // own AP removed
        XCTAssertEqual(a.loads.first(where: { $0.channel == 6 })?.networks, 2)
    }

    func testStaysWhenAlreadyBest() {
        let nets = [net(1, -50), net(6, -55), net(11, -40)]
        let a = ChannelAdvisor.advise(band: .ghz2, networks: nets, currentChannel: 11, ownRSSI: -40)
        XCTAssertEqual(a.recommended, 11)
        XCTAssertFalse(a.shouldSwitch)
    }

    func testOccupied5() {
        XCTAssertEqual(ChannelAdvisor.occupied5(channel: 157, width: 80), [149, 153, 157, 161])
        XCTAssertEqual(ChannelAdvisor.occupied5(channel: 44, width: 40), [44, 48])
        XCTAssertEqual(ChannelAdvisor.occupied5(channel: 165, width: 80), [165])
        XCTAssertEqual(ChannelAdvisor.occupied5(channel: 40, width: 20), [40])
    }

    func testRecommends5() {
        let nets = [net(149, -55, .ghz5, width: 80), net(36, -60, .ghz5, width: 80), net(44, -70, .ghz5, width: 40)]
        let a = ChannelAdvisor.advise(band: .ghz5, networks: nets, currentChannel: 153, ownRSSI: nil)
        XCTAssertEqual(a.recommended, 165)
        XCTAssertTrue(a.shouldSwitch)
    }

    func testSignalBuckets() {
        XCTAssertEqual(SignalQuality.bars(rssi: -55), 4)
        XCTAssertEqual(SignalQuality.bars(rssi: -72), 2)
        XCTAssertEqual(SignalQuality.health(rssi: -80), .poor)
    }
}

final class DiagnoserTests: XCTestCase {
    func testHealthy() {
        let d = Diagnoser.evaluate(DiagnosisInput(online: true, isWiFi: true, wifiRSSI: -52,
                                                  gatewayLatency: 3, gatewayLoss: 0,
                                                  internetLatency: 25, internetLoss: 0, internetJitter: 3,
                                                  dnsMs: 20, httpMs: 120))
        XCTAssertEqual(d.overall, .good)
        XCTAssertTrue(d.findings.isEmpty)
    }

    func testLanProblem() {
        let d = Diagnoser.evaluate(DiagnosisInput(online: true, isWiFi: true, wifiRSSI: -80,
                                                  gatewayLatency: 40, gatewayLoss: 20,
                                                  internetLatency: 60, internetLoss: 20))
        XCTAssertEqual(d.overall, .poor)
        XCTAssertEqual(d.findings.first?.health, .poor)
        XCTAssertTrue(d.summary.contains("jaringan rumah"))
        XCTAssertTrue(d.findings.contains { $0.action == .openWiFi })
    }

    func testProviderProblemAndSlowDNS() {
        let d = Diagnoser.evaluate(DiagnosisInput(online: true, isWiFi: false,
                                                  gatewayLatency: 1, gatewayLoss: 0,
                                                  internetLatency: 200, internetLoss: 30,
                                                  dnsMs: 150, httpMs: 400))
        XCTAssertEqual(d.overall, .poor)
        XCTAssertTrue(d.findings.contains { $0.action == .openSpeedTest })
        XCTAssertTrue(d.findings.contains { $0.action == .openDNS && $0.health == .fair })
    }

    func testOffline() {
        XCTAssertEqual(Diagnoser.evaluate(DiagnosisInput(online: false, isWiFi: false)).overall, .poor)
    }

    func testHourlyExtremes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(h * 3600)) }
        let samples: [(date: Date, value: Double)] = [(at(9), 100), (at(9), 110), (at(20), 30), (at(20), 40)]
        let e = HourlyInsight.extremes(samples, calendar: cal)
        XCTAssertEqual(e?.slow, 20)
        XCTAssertEqual(e?.fast, 9)
    }
}
