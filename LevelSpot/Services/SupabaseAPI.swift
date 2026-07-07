import Foundation

/// Fill these in once the Supabase project exists (supabase/README steps). The app is fully
/// functional with them empty — the reg lookup shows its "occasionally unavailable" state
/// and history stays local-only until sync ships.
enum SupabaseConfig {
    static let url = ""      // e.g. https://abcdefgh.supabase.co
    static let anonKey = ""  // the public anon key (NOT the service role key)
    static var isConfigured: Bool { !url.isEmpty && !anonKey.isEmpty }
}

struct RegistrationLookupResult: Decodable {
    let found: Bool
    let make: String?
    let model: String?
    let manufactureYear: Int?
}

enum SupabaseAPI {
    /// Registration -> make/model/year via the mot-lookup Edge Function. The DVSA secrets
    /// live only in the function's environment; this client holds nothing sensitive.
    static func lookupRegistration(_ registration: String) async throws -> RegistrationLookupResult {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.url)/functions/v1/mot-lookup") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8 // fail fast to the manual list, never hang on field signal
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["registration": registration])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RegistrationLookupResult.self, from: data)
    }

    // Pitch sync (signed-in, cross-device) is deliberately absent from v1 wiring: the brief
    // requires no account for the core tool, and PitchRecord.synced already marks what a
    // future sync pass uploads. Server schema + RLS for it is live in supabase/migrations.
}
