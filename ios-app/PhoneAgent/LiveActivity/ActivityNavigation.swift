import Foundation

struct ActivityNavigation: Equatable {
    let id = UUID()
    let route: AgentActivityRoute
    let messageID: UUID?
}
