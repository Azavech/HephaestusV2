// OWNER: ui-chats — the resources a composer adds from its paperclip menu: what a search result
// links, and which chips a composer shows and sends (docs/chats.md › Added resources).
import Foundation
import HephaestusCore

enum AddedResources {
    /// The resource a search result adds to a composer of a chat of the project `chatProjectID`:
    /// its kind, its short name and its `<item>`, with `added` true. A docs or code file of another
    /// project than the chat's ends with ` in project <ID>`. Nil for a target no result has.
    static func resource(for result: SearchResult, chatProjectID: String) -> ChatLinkedItem? {
        switch result.target {
        case .project(let projectID):
            return resource(.project, projectID, "project \(projectID) “\(result.title)”")
        case .ticket(let ticketID):
            return resource(.ticket, ticketID, "ticket \(ticketID) “\(title(of: result, after: ticketID))”")
        case .bundle(let bundleID):
            return resource(.bundle, bundleID, "bundle \(bundleID) “\(title(of: result, after: bundleID))”")
        case .doc(let projectID, let path, _):
            return resource(.docsFile, fileName(path), "docs file \(path)" + project(projectID, unlessIn: chatProjectID))
        case .file(let projectID, let path, let line):
            let place = line.map { ":\($0)" } ?? ""
            return resource(.codeFile, fileName(path) + place,
                            "code file \(path)\(place)" + project(projectID, unlessIn: chatProjectID))
        case .chat(let chatID):
            return resource(.chat, result.title, "chat “\(result.title)” (\(chatID.uuidString))")
        case .skill(let name):
            return resource(.skill, name, "skill \(name)")
        case .webTab:
            // The result's title is the tab's title and its subtitle the tab's URL.
            let url = result.subtitle ?? ""
            if result.title.isEmpty {
                return resource(.webTab, url, "web tab \(url)")
            }
            return resource(.webTab, result.title, "web tab “\(result.title)” \(url)")
        case .section:
            return nil
        }
    }

    /// The linked item chips a composer shows: the linked items whose `<item>` no added resource
    /// has, since an item that is already an added resource shows only its resource chip.
    static func shownLinkedItems(_ linked: [LinkedItem], resources: [ChatLinkedItem]) -> [LinkedItem] {
        let added = Set(resources.map(\.text))
        return linked.filter { !added.contains($0.text) }
    }

    /// The resources of a composer once `resource` is added: unchanged when a chip of the composer,
    /// a linked item chip or a resource chip, already shows its `<item>`.
    static func adding(_ resource: ChatLinkedItem, to resources: [ChatLinkedItem], linked: [LinkedItem]) -> [ChatLinkedItem] {
        guard !resources.contains(where: { $0.text == resource.text }), !linked.contains(where: { $0.text == resource.text })
        else { return resources }
        return resources + [resource]
    }

    /// What Send passes in `ChatMessageInput.linkedItems`, in chip order: the linked items shown,
    /// then the added resources.
    static func sent(linked: [LinkedItem], resources: [ChatLinkedItem]) -> [ChatLinkedItem] {
        shownLinkedItems(linked, resources: resources).map(\.chatLinkedItem) + resources
    }

    private static func resource(_ kind: ChatLinkedItemKind, _ name: String, _ text: String) -> ChatLinkedItem {
        ChatLinkedItem(kind: kind, name: name, text: text, added: true)
    }

    /// The title of a ticket or bundle result, whose `title` is `<id> <title>`.
    private static func title(of result: SearchResult, after id: String) -> String {
        result.title.hasPrefix(id + " ") ? String(result.title.dropFirst(id.count + 1)) : result.title
    }

    /// ` in project <ID>` for a file of another project than the chat's.
    private static func project(_ projectID: String, unlessIn chatProjectID: String) -> String {
        projectID == chatProjectID ? "" : " in project \(projectID)"
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
