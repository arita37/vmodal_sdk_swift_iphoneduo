import Foundation
import VModalSDK

actor SimulationTransport: VModalTransport {
    func send(_ request: VModalRequest) async throws -> VModalResponse {
        let body = request.url.path.hasSuffix("health") ? #"{"status":"ok","version":"simulation"}"# : "{}"
        let data = Data(body.utf8)
        return VModalResponse(statusCode: 200, declaredLength: Int64(data.count), body: AsyncThrowingStream { value in value.yield(data); value.finish() })
    }
    func close() async {}
}

do {
    let config = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "simulation")
    let client = VModalClient(config: config, transport: SimulationTransport())
    let health = try await client.health(); print("simulation status=\(health.status) version=\(health.version ?? "")")
    await client.close()
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
