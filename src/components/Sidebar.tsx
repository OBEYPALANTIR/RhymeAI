import React from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sparkles, Wand2, AlignLeft, Loader2, ChevronRight, ChevronDown } from 'lucide-react';
import { syllable } from 'syllable';

interface RhymeContext {
  targetLine: string | null;
  currentLetter: string;
  stanzaLines: string[];
  currentLineIndex: number;
}

interface SidebarProps {
  isFocused: boolean;
  isContextExpanded: boolean;
  setIsContextExpanded: (expanded: boolean) => void;
  theme: string;
  setTheme: (theme: string) => void;
  rhymeContext: RhymeContext;
  rhymeScheme: string;
  setRhymeScheme: (scheme: string) => void;
  customRhymeScheme: string;
  setCustomRhymeScheme: (scheme: string) => void;
  activeRhymeScheme: string;
  rhymeType: string;
  setRhymeType: (type: string) => void;
  rhymeOptions: string[];
  isHighlightEnabled: boolean;
  setIsHighlightEnabled: (enabled: boolean) => void;
  isSyllableColoringEnabled: boolean;
  setIsSyllableColoringEnabled: (enabled: boolean) => void;
  handleGetSuggestions: () => void;
  isLoading: boolean;
  suggestions: string[];
  insertSuggestion: (suggestion: string) => void;
  lyrics: string;
}

export function Sidebar({
  isFocused,
  isContextExpanded,
  setIsContextExpanded,
  theme,
  setTheme,
  rhymeContext,
  rhymeScheme,
  setRhymeScheme,
  customRhymeScheme,
  setCustomRhymeScheme,
  activeRhymeScheme,
  rhymeType,
  setRhymeType,
  rhymeOptions,
  isHighlightEnabled,
  setIsHighlightEnabled,
  isSyllableColoringEnabled,
  setIsSyllableColoringEnabled,
  handleGetSuggestions,
  isLoading,
  suggestions,
  insertSuggestion,
  lyrics
}: SidebarProps) {
  const renderSuggestionWithRhymeHighlight = (suggestion: string) => {
    if (!isHighlightEnabled) return suggestion;

    // Match everything up to the last word, the last word itself, and any trailing punctuation
    const match = suggestion.match(/(.*?)(\b\w+\b)([^\w]*)$/);
    if (match) {
      const [_, prefix, word, suffix] = match;
      return (
        <>
          {prefix}
          <span className="text-indigo-200 font-medium underline decoration-indigo-400/60 underline-offset-4 drop-shadow-[0_0_8px_rgba(129,140,248,0.5)]">
            {word}
          </span>
          {suffix}
        </>
      );
    }
    return suggestion;
  };

  return (
    <aside
      className={`w-full md:w-96 border-t md:border-t-0 md:border-l border-white/10 glass-panel flex flex-col h-[55vh] md:h-screen fixed bottom-0 md:right-0 md:top-0 z-40 bg-[#0a0a0a]/95 backdrop-blur-2xl shadow-2xl shadow-black transition-transform duration-500 ease-[cubic-bezier(0.16,1,0.3,1)] ${
        isFocused ? 'translate-y-full md:translate-y-0 md:translate-x-full' : 'translate-y-0 md:translate-x-0'
      }`}
    >
      <div className="p-6 border-b border-white/10">
        <button
          onClick={() => setIsContextExpanded(!isContextExpanded)}
          className="w-full flex items-center justify-between text-left group cursor-pointer"
        >
          <h2 className="text-lg font-medium flex items-center gap-2">
            <Wand2 className="w-5 h-5 text-indigo-400" />
            Context & Theme
          </h2>
          <ChevronDown className={`w-5 h-5 text-white/40 transition-transform duration-300 ${isContextExpanded ? 'rotate-180' : ''}`} />
        </button>

        <AnimatePresence initial={false}>
          {isContextExpanded && (
            <motion.div
              initial={{ height: 0, opacity: 0, marginTop: 0 }}
              animate={{ height: 'auto', opacity: 1, marginTop: 16 }}
              exit={{ height: 0, opacity: 0, marginTop: 0 }}
              transition={{ duration: 0.3, ease: [0.16, 1, 0.3, 1] }}
              className="overflow-hidden"
            >
              <textarea
                value={theme}
                onChange={(e) => setTheme(e.target.value)}
                placeholder="What is this song about? (e.g., A heartbreak in neon-lit Tokyo, overcoming a fear of the ocean...)"
                className="w-full bg-black/20 border border-white/10 rounded-xl p-3 text-sm outline-none focus:border-indigo-500/50 transition-colors resize-none h-24 placeholder:text-white/30"
              />
            </motion.div>
          )}
        </AnimatePresence>

        {!isContextExpanded && theme && (
          <p className="text-sm text-white/50 mt-2 truncate pr-6">
            {theme}
          </p>
        )}
      </div>

      <div className="flex-1 overflow-y-auto p-6 flex flex-col gap-6">
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-medium text-white/70 flex items-center gap-2">
              <AlignLeft className="w-4 h-4" />
              Target Line
            </h3>
            {rhymeContext.targetLine && (
              <span className="text-xs font-mono bg-white/10 px-2 py-1 rounded-md text-white/60">
                {syllable(rhymeContext.targetLine)} syllables
              </span>
            )}
          </div>

          <div className="bg-white/5 rounded-lg p-4 border border-white/5 min-h-[3rem] flex items-center">
            {rhymeContext.targetLine ? (
              <p className="font-serif italic text-white/90">"{rhymeContext.targetLine}"</p>
            ) : (
              <p className="text-sm text-white/30 italic">New rhyme sound (or place cursor on a line)</p>
            )}
          </div>

          <div className="space-y-2 pt-2">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-medium text-white/70">Rhyme Scheme</h3>
              <select
                value={rhymeScheme}
                onChange={(e) => setRhymeScheme(e.target.value)}
                className="bg-black/40 border border-white/10 rounded-lg px-2 py-1 text-xs text-white outline-none cursor-pointer"
              >
                <option value="AABB">AABB</option>
                <option value="ABAB">ABAB</option>
                <option value="ABCB">ABCB</option>
                <option value="AAAA">AAAA</option>
                <option value="Custom">Custom...</option>
              </select>
            </div>
            {rhymeScheme === 'Custom' && (
              <input
                type="text"
                value={customRhymeScheme}
                onChange={(e) => setCustomRhymeScheme(e.target.value.toUpperCase().replace(/[^A-Z]/g, ''))}
                placeholder="e.g. AABBCC"
                className="w-full bg-black/40 border border-white/10 rounded-lg px-3 py-2 text-sm text-white outline-none focus:border-indigo-500/50 transition-colors"
              />
            )}

            {/* Visual Display of Current Stanza */}
            {lyrics && (
              <div className="mt-2 bg-black/40 rounded-xl border border-white/10 p-3 font-mono text-xs max-h-40 overflow-y-auto">
                {rhymeContext.stanzaLines.map((line, i) => {
                  const schemeLetters = activeRhymeScheme.split('');
                  const letter = schemeLetters.length > 0 ? schemeLetters[i % schemeLetters.length] : '-';
                  const isCurrent = i === rhymeContext.currentLineIndex;
                  return (
                    <div key={i} className={`flex gap-3 mb-1 ${isCurrent ? 'opacity-100' : 'opacity-50'}`}>
                      <span className={`font-bold w-4 shrink-0 ${isCurrent ? 'text-indigo-400' : 'text-white/40'}`}>
                        {letter}
                      </span>
                      <span className="truncate text-white/80">
                        {line || (isCurrent ? <span className="text-white/30 italic">Typing here...</span> : '')}
                      </span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          <div className="space-y-2 pt-2">
            <h3 className="text-sm font-medium text-white/70">Rhyme Density</h3>
            <div className="flex bg-black/40 p-1 rounded-xl border border-white/10">
              {rhymeOptions.map(option => (
                <button
                  key={option}
                  onClick={() => setRhymeType(option)}
                  className={`flex-1 text-xs font-medium py-2 rounded-lg transition-all duration-200 ${
                    rhymeType === option
                      ? 'bg-indigo-600 text-white shadow-md shadow-indigo-500/20'
                      : 'text-white/50 hover:text-white/90 hover:bg-white/5'
                  }`}
                >
                  {option.split(' ')[0]}
                </button>
              ))}
            </div>
          </div>

          <div className="flex items-center justify-between pt-2">
            <h3 className="text-sm font-medium text-white/70">Highlight Rhymes</h3>
            <button
              onClick={() => setIsHighlightEnabled(!isHighlightEnabled)}
              className={`w-10 h-5 rounded-full transition-colors relative cursor-pointer ${
                isHighlightEnabled ? 'bg-indigo-600' : 'bg-white/10'
              }`}
            >
              <motion.div
                className="w-4 h-4 bg-white rounded-full absolute top-0.5"
                animate={{ left: isHighlightEnabled ? '1.25rem' : '0.125rem' }}
                transition={{ type: "spring", stiffness: 500, damping: 30 }}
              />
            </button>
          </div>

          <div className="flex items-center justify-between pt-2">
            <h3 className="text-sm font-medium text-white/70">Color Syllables</h3>
            <button
              onClick={() => setIsSyllableColoringEnabled(!isSyllableColoringEnabled)}
              className={`w-10 h-5 rounded-full transition-colors relative cursor-pointer ${
                isSyllableColoringEnabled ? 'bg-indigo-600' : 'bg-white/10'
              }`}
            >
              <motion.div
                className="w-4 h-4 bg-white rounded-full absolute top-0.5"
                animate={{ left: isSyllableColoringEnabled ? '1.25rem' : '0.125rem' }}
                transition={{ type: "spring", stiffness: 500, damping: 30 }}
              />
            </button>
          </div>

          <button
            onClick={handleGetSuggestions}
            disabled={!lyrics || isLoading}
            className="w-full py-3 px-4 bg-indigo-600 hover:bg-indigo-500 disabled:bg-white/5 disabled:text-white/30 text-white rounded-xl font-medium transition-all flex items-center justify-center gap-2 shadow-lg shadow-indigo-500/20 disabled:shadow-none cursor-pointer"
          >
            {isLoading ? (
              <>
                <Loader2 className="w-4 h-4 animate-spin" />
                Thinking...
              </>
            ) : (
              <>
                <Sparkles className="w-4 h-4" />
                Suggest Next Line
              </>
            )}
          </button>
        </div>

        <AnimatePresence mode="popLayout">
          {suggestions.length > 0 && (
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -20 }}
              className="space-y-3"
            >
              <h3 className="text-sm font-medium text-white/70">Suggestions</h3>
              <div className="space-y-2">
                {suggestions.map((suggestion, idx) => (
                  <motion.button
                    key={idx}
                    initial={{ opacity: 0, y: 15, scale: 0.95 }}
                    animate={{ opacity: 1, y: 0, scale: 1 }}
                    whileHover={{ scale: 1.02 }}
                    whileTap={{ scale: 0.98 }}
                    transition={{
                      type: "spring",
                      stiffness: 400,
                      damping: 25,
                      delay: idx * 0.08
                    }}
                    onClick={() => insertSuggestion(suggestion)}
                    className="w-full text-left p-4 rounded-xl bg-white/5 hover:bg-white/10 border border-white/5 hover:border-indigo-500/40 transition-all group flex items-start justify-between gap-4 cursor-pointer hover:shadow-lg hover:shadow-indigo-500/10"
                  >
                    <span className="font-serif text-white/90 leading-relaxed">
                      {renderSuggestionWithRhymeHighlight(suggestion)}
                    </span>
                    <div className="flex items-center gap-3 shrink-0 mt-1">
                      <span className="text-xs font-mono text-white/40 bg-white/5 px-2 py-1 rounded-md">
                        {syllable(suggestion)}
                      </span>
                      <ChevronRight className="w-4 h-4 text-white/20 group-hover:text-indigo-400 transition-all group-hover:translate-x-1" />
                    </div>
                  </motion.button>
                ))}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </aside>
  );
}
