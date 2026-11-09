// OWNER: ui-chats — the pinned font card (docs/chats.md › Pinned font card).
import HephaestusCore
import HephaestusText
import SwiftUI

/// The layout of the font card: one-line rows, at most 8 visible, and a preview at most 200 pt
/// high (docs/chats.md › Pinned font card).
enum FontCardLayout {
    static let rowHeight: CGFloat = 32
    static let visibleRows = 8
    static let previewMaxHeight: CGFloat = 200
    /// The card's text size, at which the rows are drawn.
    static let textSize: CGFloat = 13

    /// The height of the list's visible area: its rows, at most `visibleRows`.
    static func listHeight(count: Int) -> CGFloat {
        CGFloat(min(visibleRows, max(1, count))) * rowHeight
    }
}

/// The font request of a chat: the question, a search field, the list of fonts, `Weight` and
/// `Size`, the preview of the sample, `Answer another way`, Skip and Submit.
struct FontCard: View {
    @Bindable var model: ChatViewModel
    let request: FontItem
    let minimize: () -> Void
    @State private var previewHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Font")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button(action: minimize) {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            MarkdownView(markdown: request.question)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            TextField("Search fonts", text: $model.fontSearch)
                .textFieldStyle(.roundedBorder)
            list
            controls
            preview
            otherRow
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipFont()
                }
                .disabled(model.isSubmittingFont)
                Button("Submit") {
                    model.submitFont()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitFont)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: request.requestID, initial: true) {
            model.fontRequestShown(request)
        }
        .onChange(of: model.fontSearch) {
            model.searchFonts(request)
        }
        .onChange(of: model.fontOther) { _, text in
            if !text.isEmpty {
                model.fontChoice = .other
            }
        }
    }

    /// The suggestions, then the search results; at most 8 rows visible.
    private var list: some View {
        let rows = model.fontRows(request)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    rowView(row)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: FontCardLayout.listHeight(count: rows.count))
        .frame(maxWidth: .infinity)
        .id(model.fontFacesRevision)
    }

    /// One font: its text in its font, a star at the trailing edge of the recommended suggestion,
    /// and an accent background while selected.
    private func rowView(_ row: FontChoice) -> some View {
        let selected = model.fontChoice == row
        let recommended = row == .suggestion(request.recommended)
        let text = model.fontRowText(row)
        return Button {
            model.selectFont(row)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: text.label)
                    .font(text.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if recommended {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: FontCardLayout.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The `Weight` menu, then the `Size` field followed by `pt`; disabled while a text style or
    /// `Answer another way` is selected.
    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Weight", selection: Binding(get: { model.fontWeight }, set: { model.setFontWeight($0) })) {
                ForEach(model.fontWeights, id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text("Size")
            TextField("", text: $model.fontSize)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text("pt")
            Spacer()
        }
        .disabled(!model.fontControlsEnabled)
    }

    /// The sample drawn in the selected font; at most 200 pt high, scrolling inside when taller;
    /// empty while no font is selected or the size is not one.
    private var preview: some View {
        ScrollView(.vertical) {
            Group {
                if let font = model.selectedFont {
                    Text(verbatim: request.sample)
                        .font(FontFaces.font(font, size: nil))
                } else {
                    Text(verbatim: " ")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                previewHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(FontCardLayout.previewMaxHeight, max(previewHeight, 1)))
        .id(model.fontFacesRevision)
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.fontChoice == .other) {
                model.fontChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.fontChoice = .other
                    }
                ChatTextEditor(text: $model.fontOther, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }
}

// MARK: - The card's state and actions

extension ChatViewModel {
    /// The card appeared for a request: the recommended suggestion selected, `Weight` and `Size`
    /// set by it when it is a family font and `Regular` and `17` otherwise, the field and the
    /// search empty; then the catalogue of this Mac and of the project is read. The same request
    /// keeps its state.
    func fontRequestShown(_ request: FontItem) {
        guard fontRequestID != request.requestID else { return }
        fontRequestID = request.requestID
        fontWeight = "Regular"
        fontWeightValue = 0
        fontSize = "17"
        fontOther = ""
        fontSearch = ""
        selectFont(.suggestion(request.recommended))
        let fonts = ProjectFonts(connection: workspace.connection, projectID: chatProjectID)
        projectFonts = fonts
        searchFonts(request)
        Task {
            let families = await fonts.families()
            let catalog = await Task.detached { FontCatalog(installed: FontCatalog.installed, project: families) }.value
            guard fontRequestID == request.requestID else { return }
            fontCatalog = catalog
            if case .suggestion(let suggestion) = fontChoice, suggestion == request.recommended {
                selectFont(fontChoice)
            }
            searchFonts(request)
            await fonts.loadFaces(of: families)
            fontFacesRevision += 1
        }
    }

    /// The search of docs/chats.md › Font search over the card's catalogue.
    func searchFonts(_ request: FontItem) {
        fontResults = fontCatalog.search(fontSearch, excludingSuggestions: request.suggestions)
    }

    /// The rows of the list: the suggestions in Claude's order, then the search results.
    func fontRows(_ request: FontItem) -> [FontChoice] {
        request.suggestions.map { FontChoice.suggestion($0) } + fontResults.map { result in
            switch result {
            case .family(let name): return .family(name)
            case .textStyle(let style): return .textStyle(style)
            }
        }
    }

    /// What a row reads and the font it is drawn in (docs/chats.md › Pinned font card).
    func fontRowText(_ choice: FontChoice) -> (label: String, font: Font) {
        let size = FontCardLayout.textSize
        switch choice {
        case .suggestion(let text):
            guard let font = FontNotation(text) else { return (text, .system(size: size)) }
            switch font {
            case .textStyle(let style): return (font.label, .system(FontFaces.textStyle(style)))
            case .family(let family, let weight, _):
                return (font.label, FontFaces.font(family: family, weight: weight, size: size) ?? .system(size: size))
            }
        case .family(let name):
            let face = fontCatalog.family(named: name).flatMap(FontCatalog.nameFace(of:))
            let drawn = face.flatMap { FontFaces.font(family: name, weight: $0.name, size: size) }
            return (name, drawn ?? .system(size: size))
        case .textStyle(let style):
            return (style.notation, .system(FontFaces.textStyle(style)))
        case .other:
            return ("", .system(size: size))
        }
    }

    /// Selecting a row: a family suggestion sets `Weight` and `Size`; a family of the search
    /// results keeps them, the weight following docs/chats.md › Nearest weight.
    func selectFont(_ choice: FontChoice) {
        fontChoice = choice
        switch choice {
        case .suggestion(let text):
            guard case .family(let family, let weight, let size)? = FontNotation(text) else { return }
            fontWeight = weight
            fontWeightValue = fontCatalog.face(family: family, weight: weight)?.weight
                ?? FontCatalog.systemWeights.first { $0.name == weight }?.weight ?? 0
            fontSize = size
        case .family(let name):
            guard let family = fontCatalog.family(named: name),
                  let face = FontCatalog.nearestFace(name: fontWeight, value: fontWeightValue, in: family) else { return }
            fontWeight = face.name
            fontWeightValue = face.weight
        case .textStyle, .other:
            break
        }
    }

    /// The family of the selected row; nil for a text style or `Answer another way`.
    var selectedFontFamily: String? {
        switch fontChoice {
        case .suggestion(let text):
            guard case .family(let family, _, _)? = FontNotation(text) else { return nil }
            return family
        case .family(let name):
            return name
        case .textStyle, .other:
            return nil
        }
    }

    /// `Weight` and `Size` act on the selected family.
    var fontControlsEnabled: Bool {
        selectedFontFamily != nil
    }

    /// The weights of the `Weight` menu: those of the selected family, and the current weight
    /// when this Mac does not have it.
    var fontWeights: [String] {
        let names = selectedFontFamily.flatMap { fontCatalog.family(named: $0) }?.faces.map(\.name) ?? []
        return names.contains(fontWeight) ? names : names + [fontWeight]
    }

    func setFontWeight(_ name: String) {
        fontWeight = name
        if let family = selectedFontFamily, let face = fontCatalog.face(family: family, weight: name) {
            fontWeightValue = face.weight
        }
    }

    /// The selected font: the selected family with `Weight` and `Size`, or the selected text
    /// style; nil while `Answer another way` is selected or the field's text is not a size.
    var selectedFont: FontNotation? {
        switch fontChoice {
        case .suggestion(let text):
            guard let font = FontNotation(text) else { return nil }
            if case .textStyle = font { return font }
        case .textStyle(let style):
            return .textStyle(style)
        case .family, .other:
            break
        }
        let size = fontSize.trimmingCharacters(in: .whitespaces)
        guard let family = selectedFontFamily, FontNotation.isSize(size), let value = Double(size),
              let text = FontNotation.sizeText(value) else { return nil }
        return .family(family: family, weight: fontWeight, size: text)
    }

    /// The answer the card submits: `![](font:<font>)` for the selected font, or the field's text.
    var fontAnswer: String {
        if fontChoice == .other {
            return fontOther.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedFont.map { "![](font:\($0.text))" } ?? ""
    }

    var canSubmitFont: Bool {
        !fontAnswer.isEmpty && !isSubmittingFont
    }

    /// Submit: `chats.answerFont` with the selected answer.
    func submitFont() {
        guard canSubmitFont else { return }
        answerFontRequest(fontAnswer, action: "Submit")
    }

    /// Skip: `chats.answerFont` with `Skipped`.
    func skipFont() {
        guard !isSubmittingFont else { return }
        answerFontRequest(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores the answer of the waiting font request. An answer that fails because the request
    /// was answered on another device shows no alert.
    private func answerFontRequest(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let request = transcriptState?.waitingFontRequest else { return }
        isSubmittingFont = true
        Task {
            defer { isSubmittingFont = false }
            do {
                _ = try await workspace.call(ChatsAnswerFont.self, ChatsAnswerFont.Params(
                    chatID: uuid, requestID: request.requestID, answer: answer))
            } catch let error as EngineError where error.code == .conflict && fontAnsweredElsewhere(request.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    private func fontAnsweredElsewhere(_ itemID: String) -> Bool {
        guard case .font(let request)? = transcriptState?.item(itemID) else { return false }
        return request.answer != nil
    }
}
