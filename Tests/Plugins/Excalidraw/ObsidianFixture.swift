/// A drawing as the Obsidian Excalidraw plugin 2.29 writes it: compressed (lz-string, 256-character chunks), a text
/// with a wikilink, a shape linking a note, and an image linked by its bare name.
enum ObsidianFixture {
    static let compressed = """
        ---

        excalidraw-plugin: parsed
        tags: [excalidraw]

        ---
        ==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠==

        Notes written above the drawing.

        # Excalidraw Data

        ## Text Elements
        Hello [[Roadmap]] ^aB3dE5fG

        ## Element Links
        Rk7mQ2pZ: [[Ideas]]

        ## Embedded Files
        f0a1b2c3d4: [[photo.png]]

        %%
        ## Drawing
        ```compressed-json
        N4KAkARALgngDgUwgLgAQQQDwMYEMA2AlgCYBOuA7hADTgQBuCpAzoQPYB2KqATLZMzYBXUtiRoIACyhQ4zZAHoFAc0JRJQgEYA6bGwC2CgF7N6hbEcK4OCtptbErHALRY8RMpWdx8Q1TdIEfARcZgRmBShcZQUebR4ATm0ABho6IIR9BA4oZm4AbXAwUDBSiBJuCFwAIQBmYgBRAFYAMwBxNNLIWERKqCwoTrLMbgBGZP4ymG4eCaLIChJ1MdnJ

        yEkEQmVpGaa16AHKgAkg/DZUACU2XGJ9XDghyHIKABVDiRP8M9R8/Kubu5wAC6QMeEDYpC2hA4BDemEGH1O53+t3uYMIzAAIhl+sRuC0CGF9mdsABrBB4tAE/BhIoAX0mJTKFQkF1JAHZ9ABFHhwABaYJ64nQgWwUQ4ymCYJGaDmXQg0zQ4zlZUWxGWaFmKvWm22CNQAA5tRAiBxSZVfgBJYghZgg9FYnEU/GEhD0xnzcqU9CW/QJTAAdQALNgAG

        qC+DC8p3ZRIfYy1C1ZLGxWoY1qjWoABsQf2Gy2OzQOf2LUIwWtlRayVwo00PGw9SDDuxwVxLppbtKdPAQP4VTgcAAylF+twmRBlJDiIPCEZhRwhF9JgxCAgKNVcGTJ8IOMQAMJsM6kSoAYha54vEHADLopeCeTQwG7dKAA==
        ```
        %%
        """
}
