import SwiftUI

enum TunnelStatus: String, Codable {
    case connected
    case starting
    case stopped

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .starting:  return "Starting…"
        case .stopped:   return ""
        }
    }

    var color: Color {
        switch self {
        case .connected: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .starting:  return Color(red: 1.0,  green: 0.58, blue: 0.0)
        case .stopped:   return Color(red: 0.78, green: 0.78, blue: 0.80)
        }
    }
}

enum TunnelEnv: String, Codable {
    case production
    case staging
    case dev

    var color: Color {
        switch self {
        case .production: return Color(red: 1.0,  green: 0.23, blue: 0.19)
        case .staging:    return Color(red: 1.0,  green: 0.58, blue: 0.0)
        case .dev:        return Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }
}

struct Tunnel: Identifiable, Codable {
    let id: UUID
    var name: String
    var profile: String
    var region: String
    var ssmTarget: String
    var remoteHost: String
    var remotePort: Int
    var localPort: Int
    var env: TunnelEnv
    var status: TunnelStatus
    var keepAlive: Bool

    init(id: UUID = UUID(), name: String, profile: String = "default",
         region: String = "us-east-1", ssmTarget: String,
         remoteHost: String, remotePort: Int, localPort: Int,
         env: TunnelEnv = .dev, status: TunnelStatus = .stopped,
         keepAlive: Bool = false) {
        self.id = id
        self.name = name
        self.profile = profile
        self.region = region
        self.ssmTarget = ssmTarget
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.localPort = localPort
        self.env = env
        self.status = status
        self.keepAlive = keepAlive
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            profile: values.decode(String.self, forKey: .profile),
            region: values.decode(String.self, forKey: .region),
            ssmTarget: values.decode(String.self, forKey: .ssmTarget),
            remoteHost: values.decode(String.self, forKey: .remoteHost),
            remotePort: values.decode(Int.self, forKey: .remotePort),
            localPort: values.decode(Int.self, forKey: .localPort),
            env: values.decode(TunnelEnv.self, forKey: .env),
            status: values.decode(TunnelStatus.self, forKey: .status),
            keepAlive: values.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? false
        )
    }

    var localAddress: String { "localhost:\(localPort)" }

    func usesSameEndpoint(as other: Tunnel) -> Bool {
        profile == other.profile && region == other.region && ssmTarget == other.ssmTarget
            && remoteHost == other.remoteHost && remotePort == other.remotePort
            && localPort == other.localPort
    }
}

extension Tunnel {
    static let samples: [Tunnel] = [
        Tunnel(name: "Production Postgres", profile: "default", region: "us-east-1",
               ssmTarget: "i-0abc123def456", remoteHost: "mydb.cluster.internal",
               remotePort: 5432, localPort: 15432, env: .production, status: .connected),
        Tunnel(name: "Staging Redis", profile: "staging", region: "us-east-1",
               ssmTarget: "i-0def456abc123", remoteHost: "redis.staging.internal",
               remotePort: 6379, localPort: 16379, env: .staging, status: .starting),
        Tunnel(name: "Dev MySQL", profile: "dev", region: "ap-south-1",
               ssmTarget: "i-0xyz789abc456", remoteHost: "mysql.dev.internal",
               remotePort: 3306, localPort: 13306, env: .dev, status: .stopped),
    ]
}
