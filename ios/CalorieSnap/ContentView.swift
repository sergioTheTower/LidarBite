import SwiftUI

struct ContentView: View {
    @StateObject private var api = APIClient()

    @State private var summary: DailySummary?
    @State private var meals: [Meal] = []
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var analyzing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SummaryCard(summary: summary)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Today's meals") {
                    if meals.isEmpty {
                        Text("No meals logged yet. Tap the camera to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(meals) { meal in
                        MealRow(meal: meal)
                    }
                    .onDelete(perform: deleteMeals)
                }
            }
            .navigationTitle("CalorieSnap")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showCamera = true
                } label: {
                    Label(analyzing ? "Analyzing…" : "Snap a meal",
                          systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                .disabled(analyzing)
                .padding()
            }
            .overlay { if analyzing { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showCamera) {
                if LiDARCaptureView.deviceSupportsLiDAR {
                    LiDARCaptureView { result in
                        Task { await analyze(result.image, volumeML: result.volumeML) }
                    }
                    .ignoresSafeArea()
                } else {
                    CameraView { image in
                        Task { await analyze(image) }
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(api: api)
            }
            .alert("Something went wrong",
                   isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    private func analyze(_ image: UIImage, volumeML: Double? = nil) async {
        analyzing = true
        defer { analyzing = false }
        do {
            _ = try await api.analyze(image: image, volumeML: volumeML)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() async {
        do {
            async let s = api.summary()
            async let m = api.meals()
            summary = try await s
            meals = try await m
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteMeals(at offsets: IndexSet) {
        let ids = offsets.map { meals[$0].id }
        meals.remove(atOffsets: offsets)
        Task {
            for id in ids { try? await api.delete(mealId: id) }
            await reload()
        }
    }
}

struct SummaryCard: View {
    let summary: DailySummary?

    var body: some View {
        VStack(spacing: 8) {
            if let s = summary {
                Text("\(s.total_calories)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("of \(s.goal) kcal · \(s.remaining) remaining")
                    .foregroundStyle(.secondary)
                ProgressView(value: min(Double(s.total_calories) / Double(max(s.goal, 1)), 1))
                    .tint(s.total_calories > s.goal ? .red : .green)
                HStack(spacing: 20) {
                    macro("Protein", s.total_protein_g)
                    macro("Carbs", s.total_carbs_g)
                    macro("Fat", s.total_fat_g)
                }
                .font(.caption)
                .padding(.top, 4)
            } else {
                ProgressView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func macro(_ label: String, _ value: Double) -> some View {
        VStack {
            Text("\(Int(value))g").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name).fontWeight(.medium)
                if !meal.description.isEmpty {
                    Text(meal.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if meal.confidence < 0.6 {
                    Text("Low confidence — tap to check")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text("\(meal.calories) kcal").fontWeight(.semibold)
        }
    }
}
