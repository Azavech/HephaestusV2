import Foundation
import Testing
@testable import HephaestusCore

/// A method no engine registers.
private enum UnknownTestMethod: EngineMethod {
    static let name = "bogus.method"
    typealias Params = Empty
    typealias Result = Empty
}

/// `projects.get` sent without its params.
private enum ProjectsGetWithoutParams: EngineMethod {
    static let name = "projects.get"
    typealias Params = Empty
    typealias Result = ProjectDetail
}

/// `settings.get` read as another result type.
private enum SettingsGetAsTicket: EngineMethod {
    static let name = "settings.get"
    typealias Params = Empty
    typealias Result = Ticket
}

/// docs/engine-api.md › Dispatcher, Actors and Errors, through `LocalEngineConnection` (the JSON
/// path of every client) and `Engine.dispatch` for the other actors.
@Suite("Dispatcher")
struct DispatcherTests {
    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    static let claude = Actor.claude(chatID: chatID.uuidString)
    static let external = Actor.claude(chatID: Actor.externalChatID)

    @Test("An unknown method fails with notFound")
    func unknownMethod() async throws {
        try await withTestEngine { engine, connection, _ in
            let error = await engineError { try await connection.call(UnknownTestMethod.self) }
            #expect(error == EngineError(.notFound, "Unknown method bogus.method."))
            let raw = await engineError { try await engine.dispatch(method: "bogus.method", params: Data("{}".utf8), actor: .system) }
            #expect(raw == EngineError(.notFound, "Unknown method bogus.method."))
        }
    }

    @Test("A method not open to the actor's kind fails with forbidden before its params are decoded")
    func actorKinds() async throws {
        try await withTestEngine { engine, connection, _ in
            let questions = ChatsPostQuestions.Params(chatID: Self.chatID, questions: [])
            #expect(await engineError { try await connection.call(ChatsPostQuestions.self, questions) }
                == EngineError(.forbidden, "chats.postQuestions is not available to user."))
            #expect(await engineError { try await engine.call(DeviceInfoMethod.self, Empty(), actor: Self.claude) }
                == EngineError(.forbidden, "device.info is not available to claude."))
            let raw = await engineError { try await engine.dispatch(method: "files.read", params: Data("[]".utf8), actor: Self.claude) }
            #expect(raw == EngineError(.forbidden, "files.read is not available to claude."))
        }
    }

    @Test("The system actor may call every method")
    func systemActor() async throws {
        try await withTestEngine { engine, _, _ in
            let info = try await engine.call(DeviceInfoMethod.self, Empty(), actor: .system)
            #expect(info.id == engine.deviceID)
            let questions = ChatsPostQuestions.Params(chatID: Self.chatID, questions: [])
            #expect(await engineError { try await engine.call(ChatsPostQuestions.self, questions, actor: .system) }?.code == .invalid)
        }
    }

    @Test("Params that do not decode fail with invalid and the coding path")
    func invalidParams() async throws {
        try await withTestEngine { engine, connection, _ in
            #expect(await engineError { try await connection.call(ProjectsGetWithoutParams.self) }
                == EngineError(.invalid, "Invalid params for projects.get: projectID: required."))

            func dispatch(_ method: String, _ json: String, _ actor: Actor = .user(deviceID: engine.deviceID)) async -> EngineError? {
                await engineError { try await engine.dispatch(method: method, params: Data(json.utf8), actor: actor) }
            }
            #expect(await dispatch("projects.get", #"{"projectID": 5}"#)
                == EngineError(.invalid, "Invalid params for projects.get: projectID: must be a string."))
            #expect(await dispatch("projects.get", #"{"projectID": null}"#)
                == EngineError(.invalid, "Invalid params for projects.get: projectID: required."))
            #expect(await dispatch("projects.get", "[]")
                == EngineError(.invalid, "Invalid params for projects.get: params: must be an object."))
            #expect(await dispatch("projects.update", #"{"projectID": "HEPH", "type": "rustCrate"}"#)
                == EngineError(.invalid, "Invalid params for projects.update: type: must be one of none, goService, swiftApplication."))
            #expect(await dispatch("chats.get", #"{"chatID": "not-a-uuid"}"#)
                == EngineError(.invalid, "Invalid params for chats.get: chatID: must be a UUID."))
            #expect(await dispatch("chats.postQuestions",
                                   #"{"chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "questions": [{"label": "A", "question": "Q?", "recommended": "x"}]}"#,
                                   .system)
                == EngineError(.invalid, "Invalid params for chats.postQuestions: questions[0].options: required."))
            #expect(await dispatch("ui.open", #"{"target": {"kind": "ticket"}}"#)
                == EngineError(.invalid, "Invalid params for ui.open: target.ticketID: required."))
            #expect(await dispatch("files.write", #"{"projectID": "HEPH", "path": "a", "text": "", "expectedModified": "yesterday"}"#)?.message
                == "Invalid params for files.write: expectedModified: must be a date such as 2026-10-31T14:03:00Z.")
        }
    }

    @Test("Omitted or null params count as {} and unknown keys are ignored")
    func emptyParams() async throws {
        try await withTestEngine { engine, _, _ in
            let actor = Actor.user(deviceID: engine.deviceID)
            for params in ["", "null", " null ", #"{"unknown": [1, 2]}"#] {
                let data = try await engine.dispatch(method: "device.info", params: Data(params.utf8), actor: actor)
                #expect(try EngineJSON.decode(DeviceInfo.self, from: data).id == engine.deviceID)
            }
        }
    }

    @Test("A result that does not decode fails with internal on the connection")
    func unexpectedResult() async throws {
        try await withTestEngine { _, connection, _ in
            #expect(await engineError { try await connection.call(SettingsGetAsTicket.self) }
                == EngineError(.internal, "Unexpected result for settings.get."))
        }
    }

    @Test("The rules for Claude are checked whatever the token")
    func rulesForClaude() async throws {
        try await withTestEngine { engine, _, _ in
            func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params, _ actor: Actor = Self.claude) async -> EngineError? {
                await engineError { try await engine.call(method, params, actor: actor) }
            }
            #expect(await call(TicketsCreate.self, .init(projectID: "HEPH", title: "Title", description: "Problem"))
                == EngineError(.forbidden, "Claude cannot set a ticket title; Haiku names the ticket."))
            #expect(await call(ProjectsUpdate.self, .init(projectID: "HEPH", chatDefaults: .clear))
                == EngineError(.forbidden, "Claude cannot change chat defaults."))
            #expect(await call(ChatsImplementTicket.self, .init(ticketID: "HEPH-1", settings: ChatSettings()), Self.external)
                == EngineError(.forbidden, "Claude cannot choose chat settings."))
            #expect(await call(ChatsImplementBundle.self, .init(bundleID: "HEPH-B1", settings: ChatSettings()))
                == EngineError(.forbidden, "Claude cannot choose chat settings."))
            #expect(await call(WebTabsUpdate.self, .init(projectID: "HEPH", tabID: UUID(), locked: false))
                == EngineError(.forbidden, "Only the user can unlock a tab."))
            let questions = ChatsPostQuestions.Params(chatID: Self.chatID, questions: [])
            #expect(await call(ChatsPostQuestions.self, questions, Self.external)
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await call(ChatsPostQuestions.self, questions, .claude(chatID: UUID().uuidString))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await call(ChatsPostQuestions.self, questions)?.code == .invalid)
        }
    }

    @Test("A user cannot send an attachment with sourcePath")
    func userSourcePath() async throws {
        try await withTestEngine { _, connection, _ in
            let upload = AttachmentUpload(name: "build.log", contentType: "text/plain", sourcePath: "/Users/example/build.log")
            let error = await engineError {
                try await connection.call(TicketsCreate.self, .init(projectID: "HEPH", description: "Problem", attachments: [upload]))
            }
            #expect(error == EngineError(.forbidden, "sourcePath is accepted from Claude only."))
            let comment = await engineError {
                try await connection.call(TicketsAddComment.self, .init(ticketID: "HEPH-1", text: "", attachments: [upload]))
            }
            #expect(comment == EngineError(.forbidden, "sourcePath is accepted from Claude only."))
        }
    }

    @Test("An event reaches the subscriber of a connection with the caller as origin")
    func eventReachesSubscriber() async throws {
        try await withTestEngine { engine, connection, _ in
            let events = connection.events
            let settings = try await connection.call(SettingsUpdate.self, .init(formatSwiftOnSave: true))
            let event = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events))
            #expect(event.origin == .user(deviceID: engine.deviceID))
            #expect(try event.payload(SettingsUpdatedEvent.self) == settings)
            #expect(try event.decoded() == .settingsUpdated(settings))
        }
    }

    @Test("Every subscription receives the same bytes, in emission order, from its start on")
    func subscriptions() async throws {
        try await withTestEngine { engine, connection, _ in
            _ = try await connection.call(SettingsUpdate.self, .init(updateCheckIntervalMinutes: 45))
            let first = await engine.subscribe()
            let second = await engine.subscribe()
            _ = try await connection.call(SettingsUpdate.self, .init(updateCheckIntervalMinutes: 50))
            _ = try await connection.call(SettingsUpdate.self, .init(updateCheckIntervalMinutes: 55))
            var firstIterator = first.makeAsyncIterator()
            var secondIterator = second.makeAsyncIterator()
            var received: [Data] = []
            for _ in 0..<2 {
                let a = try #require(await firstIterator.next())
                let b = try #require(await secondIterator.next())
                #expect(a == b)
                received.append(a)
            }
            let intervals = try received.map {
                try EngineJSON.decode(EngineEventEnvelope.self, from: $0).payload(SettingsUpdatedEvent.self).updateCheckIntervalMinutes
            }
            #expect(intervals == [50, 55])
        }
    }

    @Test("A call that changes nothing emits no event")
    func noChangeNoEvent() async throws {
        try await withTestEngine { _, connection, _ in
            let events = connection.events
            _ = try await connection.call(SettingsUpdate.self, .init(autoUpdate: true))
            _ = try await connection.call(SettingsUpdate.self, .init(autoUpdate: false))
            let event = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events))
            #expect(try event.payload(SettingsUpdatedEvent.self).autoUpdate == false)
        }
    }

    @Test("A closed connection is disconnected and its calls fail with unavailable")
    func closedConnection() async throws {
        try await withTestEngine { engine, _, _ in
            let connection = await LocalEngineConnection(engine: engine)
            #expect(connection.state == .connected)
            let states = connection.stateUpdates
            connection.close()
            #expect(connection.state == .disconnected(reason: "Closed."))
            var iterator = states.makeAsyncIterator()
            #expect(await iterator.next() == .connected)
            #expect(await iterator.next() == .disconnected(reason: "Closed."))
            #expect(await iterator.next() == nil)
            #expect(await engineError { try await connection.call(SettingsGet.self) }?.code == .unavailable)
        }
    }

    @Test("Stopping the engine finishes its subscriptions")
    func shutdownFinishesSubscriptions() async throws {
        try await withTestEngine { engine, connection, _ in
            let raw = await engine.subscribe()
            let events = connection.events
            await engine.shutdown()
            #expect(await firstElement(of: raw) == nil)
            #expect(await firstElement(of: events) == nil)
            #expect(await firstElement(of: await engine.subscribe()) == nil)
        }
    }

    @Test("Stopping the engine marks the project data stopped, so that later background answers are not written")
    func shutdownStopsDomain() async throws {
        try await withTestEngine { engine, _, _ in
            #expect(await engine.testDomain.isStopped == false)
            await engine.shutdown()
            #expect(await engine.testDomain.isStopped)
        }
    }
}
