# Tools registry

Agents and skills reference a tool by its **role**, never by a hard tool name. When the
preferred tool is unavailable, fall back to the alternative. Reviewed on the dates below.

| Role | Preferred tool | Alternative (if unavailable) | Status | Last reviewed |
|------|----------------|------------------------------|--------|---------------|
| issue-tracker | GitHub Issues via `gh issue` | none — record the issue in the PR body | active | 2026-10-08 |
| source-control | `git` worktrees + `gh pr` (rebase-merge) | none | active | 2026-10-08 |
| ci | GitHub Actions (`android-unit-tests`, `ios-unit-tests`, CodeRabbit check) | local suites only, and say so in the PR | active | 2026-10-08 |
| reviewer | Codex (`@codex review`), CodeRabbit, Copilot on the PR | `code-reviewer` user-level agent as an independent non-author verdict | active | 2026-10-08 |
| evidence-host | secret GitHub gist (path-free summary, owner's OK each time) | PR comment with the same text | active | 2026-10-08 |
| android-unit-tests | `./gradlew :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin` with the Android Studio Preview JBR as `JAVA_HOME` | none | active | 2026-10-08 |
| android-device | emulator `RhymeAI_UX_Phone_20260910_AndroidAgent` (serve-avd MCP, ARTEMIS for UI flows) | none — never create or erase devices | active | 2026-10-08 |
| ios-tests | `xcodebuild test -only-testing "Writers BlockTests"` on simulator `FA565D4C-561C-432C-BBC6-1EB55406CEDA` (iPad, iOS 26.5) | `A1619FBB-66A0-4B54-93BE-DC9787866101` (iPhone 18 Pro, iOS 27) | active | 2026-10-08 |
| eval-tests | `python3 -B -m unittest discover -s finetune/eval -p 'test_*.py'` | none | active | 2026-10-08 |
| local-inference | `/opt/homebrew/bin/llama-server` (b9950) with the gemma4 envelope | `~/src/llama.cpp` build | active | 2026-10-08 |
| student-model | shipped GGUFs under `/Volumes/Untitled/models/rhymeai/students-v21-20261006/` | Hugging Face `Shayde182/rhymeai-gemma-4-gguf` at the catalog revision | active | 2026-10-08 |
| teacher-model | Gemma 4 31B-it Q4_K_M via llama-server (`-c 4096 -np 1 --jinja --reasoning off --swa-full`) | none — teacher data needs this machine | active | 2026-10-08 |
| student-training | Colab Pro A100 + unsloth notebooks from the colab package | none — owner's units gate | active | 2026-10-08 |
| model-host | Hugging Face CLI (owner's account) | none | active | 2026-10-08 |
| browser-automation | Claude in Chrome (Colab, Drive, HF web) | built-in browser pane | active | 2026-10-08 |
| native-ui | computer-use MCP (Google consent popups, native dialogs) | ask the owner to click | active | 2026-10-08 |
| language-server-kotlin | `kotlin-lsp-anthropics` plugin (JetBrains kotlin-lsp; AGP support experimental) | `rg` + reading the file | active (installed 2026-10-08, user scope) | 2026-10-08 |
| language-server-swift | `swift-lsp-anthropics` plugin (sourcekit-lsp from Xcode) | `rg` + reading the file | active (installed 2026-10-08, user scope) | 2026-10-08 |
| gguf-inspect | gguf-py CLIs (`gguf-dump`, `gguf-hash`, `gguf_new_metadata.py`; PyPI `gguf`, also in the llama.cpp source checkout); `llama-tokenize` for tokenizer parity | the notebook's `gguf_layout` reader | active | 2026-10-08 |
| colab-runner | `colab-mcp` (Google's official Colab MCP, user-scope stdio via `uvx`; needs a one-time OAuth grant; A100 runtime selection unverified) | Claude in Chrome driving the Colab web UI | accepted, unverified | 2026-10-08 |
| eval-tracking | `inspect-ai` (local `.eval` logs + `inspect view`, against llama-server's OpenAI-compatible endpoint); install into a venv on first use | scorecard JSON files compared by `eval_student.py --compare` | accepted, not installed | 2026-10-08 |
