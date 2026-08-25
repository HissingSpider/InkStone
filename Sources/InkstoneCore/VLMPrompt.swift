import Foundation

/// The prompt used when a page escalates to a vision model.
///
/// Two things matter here and both are easy to get wrong. First, the model must
/// transcribe rather than summarise — an LLM shown a page of notes will happily
/// tidy them into prose it thinks you wanted, which silently destroys content.
/// Second, its output has to be Obsidian markdown that slots straight into a
/// note, so the prompt fixes the vocabulary of markdown it may emit and forbids
/// the wrapper text models like to add.
public enum VLMPrompt {

    public static let system = """
        You transcribe handwritten notes into Obsidian-flavoured Markdown.

        You are a transcriber, not an editor or a summariser. The person who \
        wrote these notes wants their own words back, exactly, with the layout \
        preserved. Anything you add, drop, reorder or rephrase is data loss.
        """

    /// The per-page instruction. `hasDiagrams` switches on placeholder output;
    /// `visionDraft` is the local OCR attempt, given to the model as a hint.
    public static func user(
        pageNumber: Int, notebook: String, hasDiagrams: Int, visionDraft: String?
    ) -> String {
        var sections: [String] = []

        sections.append("""
            Transcribe page \(pageNumber) of the notebook "\(notebook)".

            Rules:
            - Transcribe every word you can read, in the order it appears on the page.
            - Preserve the line structure. One line on the page is one line of output.
            - Use Markdown only where the page itself is structured that way: `#`/`##` \
            for text written as a heading (larger, underlined, boxed), `-` for bulleted \
            items, `1.` for numbered items, `- [ ]` for checkboxes, two-space indents \
            for nested items, `> ` for text the writer set apart in a margin or box.
            - Mark every distinct topic on the page with a heading, at the level its \
            size and position imply: a main topic as `##`, a sub-topic under it as `###`. \
            Writers often start a new idea with a short phrase that is only slightly \
            larger, or underlined, or set on its own line — treat that as a heading. Do \
            not invent a heading where the page has none, but do not flatten one either: \
            these headings are what split the page into separate, findable notes.
            - A word like "continued" at the top of a page is not a heading. It marks \
            more of the previous topic; transcribe it as ordinary text.
            - Keep mathematics as LaTeX between `$` for inline and `$$` for display.
            - Keep the writer's own abbreviations, symbols and shorthand. Do not expand them.
            - Fix only mechanical slips that are unambiguous: a letter clearly malformed \
            by fast handwriting, a missing closing bracket. Never rewrite a phrase because \
            it reads awkwardly.
            - Where a word is genuinely illegible, write `[?]`. Where you can read it but \
            are unsure, write your best reading followed by `[?]`. Never invent a word to \
            fill a gap.
            - Do not add a title, a summary, commentary, or any text that is not on the page.
            - Output the Markdown only. No code fence around it, no preamble, no sign-off.
            """)

        if hasDiagrams > 0 {
            sections.append("""
                This page has \(hasDiagrams) diagram\(hasDiagrams == 1 ? "" : "s") \
                (drawings, charts, sketches) that have already been cropped out as images.
                Do not attempt to describe or redraw them. Instead, write the exact token \
                `\(NoteComposer.diagramPlaceholder)` on its own line at each point in the \
                text where a diagram appears, top to bottom. Emit exactly \(hasDiagrams) \
                of them.
                """)
        }

        if let visionDraft, !visionDraft.isEmpty {
            sections.append("""
                On-device OCR produced the draft below. It is unreliable — that is why this \
                page was sent to you — but proper nouns and numbers in it are often right. \
                Use it as a hint and trust the image over the draft wherever they disagree.

                <draft>
                \(visionDraft)
                </draft>
                """)
        }

        return sections.joined(separator: "\n\n")
    }
}

extension VLMPrompt {

    /// Phrases a model uses when it declines rather than transcribes.
    ///
    /// Shown a blank or near-blank page, a model often explains itself instead
    /// of returning nothing — "I'm unable to transcribe...", "this appears to be
    /// a blank page". That explanation was being written into the vault as if it
    /// were the page's contents, which is worse than an empty note: it reads as
    /// something the user wrote.
    static let refusalPhrases = [
        "unable to transcribe", "cannot transcribe", "can't transcribe",
        "no visible handwriting", "no visible text", "no text is present",
        "appears to be a blank", "appears to be blank", "is a blank page",
        "i'm sorry", "i am sorry", "i'm unable", "i am unable",
        "there is no handwriting", "no discernible",
    ]

    /// True when `markdown` is the model talking about the page rather than
    /// transcribing it.
    ///
    /// Length and structure guard against false positives: a real transcription
    /// of a page that happens to contain one of these phrases will be longer, or
    /// will carry markdown structure, or both. A page whose entire content is an
    /// apology is not a page anyone wrote.
    public static func looksLikeRefusal(_ markdown: String) -> Bool {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 400 else { return false }

        let structural = ["#", "-", "*", ">", "|", "$", "!["]
        let hasStructure = text.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return structural.contains { trimmed.hasPrefix($0) }
        }
        guard !hasStructure else { return false }

        let lowered = text.lowercased()
        return refusalPhrases.contains { lowered.contains($0) }
    }
}
