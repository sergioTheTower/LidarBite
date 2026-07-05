import Foundation

struct Meal: Identifiable, Codable {
    let id: Int
    let name: String
    let description: String
    let calories: Int
    let protein_g: Double
    let carbs_g: Double
    let fat_g: Double
    let confidence: Double
    let logged_on: String
    let created_at: String
}

struct DailySummary: Codable {
    let day: String
    let goal: Int
    let total_calories: Int
    let total_protein_g: Double
    let total_carbs_g: Double
    let total_fat_g: Double
    let remaining: Int
    let meal_count: Int
}

struct APIError: Codable { let detail: String }
