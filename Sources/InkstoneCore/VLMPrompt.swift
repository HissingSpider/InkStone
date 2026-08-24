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
