import Foundation
import UIKit

/// Talks to the CalorieSnap backend running on your Komodo stack.
@MainActor
final class APIClient: ObservableObject {
    // Server URL + API key are user-editable in Settings and persisted.
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }
    /// Known plate/container weight (grams) subtracted from scale readings. "" = none.
    @Published var tareGrams: String {
        didSet { UserDefaults.standard.set(tareGrams, forKey: "tareGrams") }
    }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "http://localhost:8000"
        apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        tareGrams = UserDefaults.standard.string(forKey: "tareGrams") ?? ""
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func decodeError(_ data: Data) -> String {
        if let err = try? JSONDecoder().decode(APIError.self, from: data) {
            return err.detail
        }
        return "Request failed"
    }

    /// Upload a photo; the backend runs Claude vision and logs the meal.
    /// `volumeML` is a LiDAR measurement (if available). The configured tare weight
    /// is sent so Claude can subtract it from a scale reading in the photo.
    func analyze(image: UIImage, volumeML: Double? = nil) async throws -> Meal {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            throw URLError(.cannotDecodeContentData)
        }
        var req = try request("/meals/analyze", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"meal.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n".data(using: .utf8)!)

        if let volumeML { field("volume_ml", String(volumeML)) }
        if let tare = Double(tareGrams), tare > 0 { field("tare_grams", String(tare)) }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "CalorieSnap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: decodeError(data)])
        }
        return try JSONDecoder().decode(Meal.self, from: data)
    }

    func meals(day: Date = Date()) async throws -> [Meal] {
        var req = try request("/meals?day=\(Self.dayString(day))")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([Meal].self, from: data)
    }

    func summary(day: Date = Date()) async throws -> DailySummary {
        let req = try request("/meals/summary?day=\(Self.dayString(day))")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(DailySummary.self, from: data)
    }

    func delete(mealId: Int) async throws {
        let req = try request("/meals/\(mealId)", method: "DELETE")
        _ = try await URLSession.shared.data(for: req)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
