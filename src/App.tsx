import React, { useState, useRef, useEffect, useCallback, useMemo } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sparkles, Wand2, AlignLeft, Music, Loader2, ChevronRight, ChevronDown } from 'lucide-react';
import { getRhymeSuggestions } from './services/gemini';

export default function App() {
  const [theme, setTheme] = useState('');
  const [title, setTitle] = useState(() => localStorage.getItem('lyricist-title') || '');
  const [lyrics, setLyrics] = useState(() => localStorage.getItem('lyricist-lyrics') || '');
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [cursorPosition, setCursorPosition] = useState(0);
  const [isFocused, setIsFocused] = useState(false);
  const [scrollY, setScrollY] = useState(0);
  const [rhymeType, setRhymeType] = useState('Perfect Rhyme');
  const [isContextExpanded, setIsContextExpanded] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const rhymeOptions = useMemo(() => ['Perfect Rhyme', 'Near Rhyme', 'Slant Rhyme'], []);

  // Save to local storage
  useEffect(() => {
    localStorage.setItem('lyricist-title', title);
    localStorage.setItem('lyricist-lyrics', lyrics);
  }, [title, lyrics]);

  const adjustTextareaHeight = useCallback(() => {
    if (textareaRef.current) {
      const scrollContainer = textareaRef.current.closest('.overflow-y-auto');
      const currentScrollTop = scrollContainer ? scrollContainer.scrollTop : 0;
      
      textareaRef.current.style.height = 'auto';
      textareaRef.current.style.height = textareaRef.current.scrollHeight + 'px';
      
      if (scrollContainer) {
        scrollContainer.scrollTop = currentScrollTop;
      }
    }
  }, []);

  // Auto-resize textarea on lyrics change
  useEffect(() => {
    adjustTextareaHeight();
  }, [lyrics, adjustTextareaHeight]);

  // Attach event listeners for resize
  useEffect(() => {
    window.addEventListener('resize', adjustTextareaHeight);
    if (document.fonts) {
      document.fonts.ready.then(adjustTextareaHeight);
    }
    
    return () => {
      window.removeEventListener('resize', adjustTextareaHeight);
    };
  }, [adjustTextareaHeight]);

  // Extract the current line based on cursor position
  const getCurrentLine = useCallback(() => {
    if (!lyrics) return '';
    const textBeforeCursor = lyrics.substring(0, cursorPosition);
    const linesBefore = textBeforeCursor.split('\n');
    const currentLineIndex = linesBefore.length - 1;
    
    const allLines = lyrics.split('\n');
    // If the current line is empty, maybe look at the previous line
    let targetLine = allLines[currentLineIndex].trim();
    if (!targetLine && currentLineIndex > 0) {
      targetLine = allLines[currentLineIndex - 1].trim();
    }
    return targetLine;
  }, [lyrics, cursorPosition]);

  const handleGetSuggestions = useCallback(async () => {
    const currentLine = getCurrentLine();
    if (!currentLine) return;

    setIsLoading(true);
    try {
      const results = await getRhymeSuggestions(theme, lyrics, currentLine, rhymeType);
      setSuggestions(results);
    } catch (error) {
      console.error(error);
    } finally {
      setIsLoading(false);
    }
  }, [getCurrentLine, theme, lyrics, rhymeType]);

  const insertSuggestion = useCallback((suggestion: string) => {
    if (!textareaRef.current) return;
    
    const textBeforeCursor = lyrics.substring(0, cursorPosition);
    const textAfterCursor = lyrics.substring(cursorPosition);
    
    // Determine if we need a newline
    const needsNewline = textBeforeCursor.length > 0 && !textBeforeCursor.endsWith('\n');
    const insertText = (needsNewline ? '\n' : '') + suggestion + '\n';
    
    const newLyrics = textBeforeCursor + insertText + textAfterCursor;
    setLyrics(newLyrics);
    
    // Update cursor position state
    const newPosition = cursorPosition + insertText.length;
    setCursorPosition(newPosition);

    setTimeout(() => {
      if (textareaRef.current) {
        textareaRef.current.selectionStart = newPosition;
        textareaRef.current.selectionEnd = newPosition;
        textareaRef.current.focus();
      }
    }, 0);
    
    setSuggestions([]);
  }, [lyrics, cursorPosition]);

  const handleKeyUp = useCallback((e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    setCursorPosition(e.currentTarget.selectionStart);
  }, []);

  const handleClick = useCallback((e: React.MouseEvent<HTMLTextAreaElement>) => {
    setCursorPosition(e.currentTarget.selectionStart);
  }, []);

  const renderSuggestionWithRhymeHighlight = useCallback((suggestion: string) => {
    // Match everything up to the last word, the last word itself, and any trailing punctuation
    const match = suggestion.match(/(.*?)(\b\w+\b)([^\w]*)$/);
    if (match) {
      const [_, prefix, word, suffix] = match;
      return (
        <React.Fragment key={suggestion}>
          {prefix}
          <span className="text-indigo-200 font-medium underline decoration-indigo-400/60 underline-offset-4 drop-shadow-[0_0_8px_rgba(129,140,248,0.5)]">
            {word}
          </span>
          {suffix}
        </React.Fragment>
      );
    }
    return suggestion;
  }, []);

  const currentLineDisplay = useMemo(() => getCurrentLine(), [getCurrentLine]);
  const wordCount = useMemo(() => lyrics.split(/\s+/).filter(w => w.length > 0).length, [lyrics]);

  return (
    <div className="min-h-screen bg-[#0a0a0a] text-white overflow-hidden relative flex flex-col md:flex-row">
      {/* Main Editor Area */}
      <main className="flex-1 flex flex-col h-screen relative w-full">
        {/* Header */}
        <motion.header 
          animate={{ y: isFocused ? '-100%' : 0, opacity: isFocused ? 0 : 1 }}
          transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
          className="h-16 border-b border-white/10 flex items-center px-6 justify-between shrink-0 glass-panel absolute top-0 w-full z-20 bg-[#0a0a0a]/90 backdrop-blur-md"
        >
          <div className="flex items-center gap-2 text-white/80">
            <Music className="w-5 h-5 text-indigo-400" />
            <h1 className="font-medium tracking-wide">Lyricist AI</h1>
          </div>
          <div className="flex items-center gap-4 text-sm text-white/50">
            <span>{wordCount} words</span>
          </div>
        </motion.header>

        {/* Editor */}
        <motion.div 
          animate={{ paddingTop: isFocused ? '0' : '4rem' }}
          transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
          className="flex-1 relative overflow-hidden flex flex-col"
        >
          <div className="absolute inset-0 pointer-events-none bg-gradient-to-b from-indigo-500/5 to-transparent opacity-50" />
          
          <div 
            className="flex-1 overflow-y-auto relative scroll-smooth"
            onScroll={(e) => setScrollY(e.currentTarget.scrollTop)}
          >
            <div className="max-w-3xl mx-auto min-h-full flex flex-col">
              {/* Sticky Title */}
              <div 
                className={`sticky top-0 z-10 bg-[#0a0a0a]/90 backdrop-blur-xl transition-all duration-300 px-8 md:px-12 ${
                  scrollY > 20 
                    ? 'py-4 border-b border-white/10 shadow-lg shadow-black/50' 
                    : 'pt-8 md:pt-12 pb-8 border-b border-transparent'
                }`}
              >
                <input
                  type="text"
                  value={title}
                  onChange={(e) => setTitle(e.target.value)}
                  placeholder="Song Title..."
                  onFocus={() => setIsFocused(true)}
                  className={`bg-transparent font-serif font-bold outline-none placeholder:text-white/20 w-full transition-all duration-300 ${
                    scrollY > 20 ? 'text-2xl md:text-3xl' : 'text-4xl md:text-5xl'
                  }`}
                />
              </div>

              {/* Lyrics Textarea */}
              <div className="px-8 md:px-12 pb-[50vh] md:pb-32 flex-1 flex flex-col">
                <textarea
                  ref={textareaRef}
                  value={lyrics}
                  onChange={(e) => {
                    setLyrics(e.target.value);
                    setCursorPosition(e.target.selectionStart);
                  }}
                  onKeyUp={handleKeyUp}
                  onClick={handleClick}
                  onFocus={() => setIsFocused(true)}
                  placeholder="Start writing your lyrics here..."
                  className="lyrics-editor w-full overflow-hidden min-h-[50vh]"
                  spellCheck={false}
                />
              </div>
            </div>
          </div>
        </motion.div>
      </main>

      {/* Sidebar / Assistant */}
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
            </div>
            
            <div className="bg-white/5 rounded-lg p-4 border border-white/5 min-h-[3rem] flex items-center">
              {currentLineDisplay ? (
                <p className="font-serif italic text-white/90">"{currentLineDisplay}"</p>
              ) : (
                <p className="text-sm text-white/30 italic">Place your cursor on a line to get suggestions.</p>
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

            <button
              onClick={handleGetSuggestions}
              disabled={!currentLineDisplay || isLoading}
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
                      <ChevronRight className="w-4 h-4 text-white/20 group-hover:text-indigo-400 shrink-0 mt-1 transition-all group-hover:translate-x-1" />
                    </motion.button>
                  ))}
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </aside>

      {/* Floating button to exit focus mode */}
      <AnimatePresence>
        {isFocused && (
          <motion.button
            initial={{ opacity: 0, y: 20, scale: 0.9 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 20, scale: 0.9 }}
            onClick={() => setIsFocused(false)}
            className="fixed bottom-8 right-8 z-30 bg-indigo-600 hover:bg-indigo-500 text-white px-5 py-3 rounded-full shadow-lg shadow-indigo-500/20 flex items-center gap-2 transition-all cursor-pointer"
          >
            <Wand2 className="w-4 h-4" />
            <span className="font-medium">Show Assistant</span>
          </motion.button>
        )}
      </AnimatePresence>
    </div>
  );
}
