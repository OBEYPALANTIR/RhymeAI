import React, { useState, useRef, useEffect, useMemo } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sparkles, Wand2, AlignLeft, Music, Loader2, ChevronRight, ChevronDown, FolderOpen, Save, Plus, Trash2, X } from 'lucide-react';
import { getRhymeSuggestions } from './services/gemini';
import { syllable } from 'syllable';

interface SongProject {
  id: string;
  title: string;
  lyrics: string;
  theme: string;
  updatedAt: number;
}

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
  const [isHighlightEnabled, setIsHighlightEnabled] = useState(true);
  const [isSyllableColoringEnabled, setIsSyllableColoringEnabled] = useState(true);
  const [rhymeScheme, setRhymeScheme] = useState('AABB');
  const [customRhymeScheme, setCustomRhymeScheme] = useState('');
  const [projects, setProjects] = useState<SongProject[]>(() => {
    const saved = localStorage.getItem('lyricist-projects');
    return saved ? JSON.parse(saved) : [];
  });
  const [currentProjectId, setCurrentProjectId] = useState<string | null>(() => localStorage.getItem('lyricist-current-project') || null);
  const [isProjectsModalOpen, setIsProjectsModalOpen] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const rhymeOptions = ['Perfect Rhyme', 'Near Rhyme', 'Slant Rhyme'];

  const wordCount = useMemo(() => {
    return lyrics.match(/\S+/g)?.length || 0;
  }, [lyrics]);

  // Save to local storage
  useEffect(() => {
    localStorage.setItem('lyricist-title', title);
    localStorage.setItem('lyricist-lyrics', lyrics);
  }, [title, lyrics]);

  useEffect(() => {
    localStorage.setItem('lyricist-projects', JSON.stringify(projects));
  }, [projects]);

  useEffect(() => {
    if (currentProjectId) {
      localStorage.setItem('lyricist-current-project', currentProjectId);
    } else {
      localStorage.removeItem('lyricist-current-project');
    }
  }, [currentProjectId]);

  // Auto-save current project
  useEffect(() => {
    if (currentProjectId) {
      setProjects(prev => prev.map(p => 
        p.id === currentProjectId 
          ? { ...p, title, lyrics, theme, updatedAt: Date.now() }
          : p
      ));
    }
  }, [title, lyrics, theme, currentProjectId]);

  const handleSaveProject = () => {
    if (!currentProjectId) {
      const newProject: SongProject = {
        id: crypto.randomUUID(),
        title: title || 'Untitled Song',
        lyrics,
        theme,
        updatedAt: Date.now()
      };
      setProjects(prev => [newProject, ...prev]);
      setCurrentProjectId(newProject.id);
    }
  };

  const handleNewProject = () => {
    setTitle('');
    setLyrics('');
    setTheme('');
    setCurrentProjectId(null);
    setIsProjectsModalOpen(false);
  };

  const handleLoadProject = (project: SongProject) => {
    setTitle(project.title);
    setLyrics(project.lyrics);
    setTheme(project.theme);
    setCurrentProjectId(project.id);
    setIsProjectsModalOpen(false);
  };

  const handleDeleteProject = (e: React.MouseEvent, id: string) => {
    e.stopPropagation();
    setProjects(prev => prev.filter(p => p.id !== id));
    if (currentProjectId === id) {
      setCurrentProjectId(null);
    }
  };

  const adjustTextareaHeight = () => {
    if (textareaRef.current) {
      const scrollContainer = textareaRef.current.closest('.overflow-y-auto');
      const currentScrollTop = scrollContainer ? scrollContainer.scrollTop : 0;
      
      textareaRef.current.style.height = 'auto';
      textareaRef.current.style.height = textareaRef.current.scrollHeight + 'px';
      
      if (scrollContainer) {
        scrollContainer.scrollTop = currentScrollTop;
      }
    }
  };

  // Auto-resize textarea
  useEffect(() => {
    adjustTextareaHeight();
    
    window.addEventListener('resize', adjustTextareaHeight);
    if (document.fonts) {
      document.fonts.ready.then(adjustTextareaHeight);
    }
    
    return () => {
      window.removeEventListener('resize', adjustTextareaHeight);
    };
  }, [lyrics]);

  const activeRhymeScheme = rhymeScheme === 'Custom' ? (customRhymeScheme || 'AABB') : rhymeScheme;

  // Extract the current line and stanza based on cursor position
  const getRhymeContext = () => {
    if (!lyrics) return { targetLine: null, currentLetter: activeRhymeScheme[0] || 'A', stanzaLines: [], currentLineIndex: 0 };
    
    const textBeforeCursor = lyrics.substring(0, cursorPosition);
    const textAfterCursor = lyrics.substring(cursorPosition);
    
    // Find stanza boundaries
    const lastDoubleNewline = textBeforeCursor.lastIndexOf('\n\n');
    const stanzaStart = lastDoubleNewline === -1 ? 0 : lastDoubleNewline + 2;
    
    const nextDoubleNewline = textAfterCursor.indexOf('\n\n');
    const stanzaEnd = nextDoubleNewline === -1 ? lyrics.length : cursorPosition + nextDoubleNewline;
    
    const currentStanza = lyrics.substring(stanzaStart, stanzaEnd);
    const stanzaLines = currentStanza.split('\n');
    
    // Calculate which line index we are currently on within the stanza
    const stanzaTextBeforeCursor = textBeforeCursor.substring(stanzaStart);
    const currentLineIndex = stanzaTextBeforeCursor.split('\n').length - 1;
    
    const schemeLetters = activeRhymeScheme.split('');
    if (schemeLetters.length === 0) return { targetLine: null, currentLetter: 'A', stanzaLines, currentLineIndex };
    
    const currentLetter = schemeLetters[currentLineIndex % schemeLetters.length];
    
    // Find the previous line in this stanza that has the same letter
    let targetLine = null;
    for (let i = currentLineIndex - 1; i >= 0; i--) {
      if (schemeLetters[i % schemeLetters.length] === currentLetter) {
        targetLine = stanzaLines[i].trim();
        if (targetLine) break; // found a non-empty line to rhyme with
      }
    }
    
    return { targetLine, currentLetter, stanzaLines, currentLineIndex };
  };

  const handleGetSuggestions = async () => {
    const context = getRhymeContext();
    if (!lyrics) return;

    setIsLoading(true);
    try {
      const results = await getRhymeSuggestions(
        theme, 
        lyrics, 
        context.targetLine, 
        rhymeType, 
        activeRhymeScheme, 
        context.currentLetter
      );
      setSuggestions(results);
    } catch (error) {
      console.error(error);
    } finally {
      setIsLoading(false);
    }
  };

  const insertSuggestion = (suggestion: string) => {
    if (!textareaRef.current) return;
    
    const textBeforeCursor = lyrics.substring(0, cursorPosition);
    const textAfterCursor = lyrics.substring(cursorPosition);
    
    // Determine if we need a newline
    const needsNewline = textBeforeCursor.length > 0 && !textBeforeCursor.endsWith('\n');
    const insertText = (needsNewline ? '\n' : '') + suggestion + '\n';
    
    const newLyrics = textBeforeCursor + insertText + textAfterCursor;
    setLyrics(newLyrics);
    
    // Update cursor position
    const newPosition = cursorPosition + insertText.length;
    setTimeout(() => {
      if (textareaRef.current) {
        textareaRef.current.selectionStart = newPosition;
        textareaRef.current.selectionEnd = newPosition;
        textareaRef.current.focus();
      }
    }, 0);
    
    setSuggestions([]);
  };

  const handleKeyUp = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    setCursorPosition(e.currentTarget.selectionStart);
  };

  const handleClick = (e: React.MouseEvent<HTMLTextAreaElement>) => {
    setCursorPosition(e.currentTarget.selectionStart);
  };

  const renderColoredLyrics = (text: string) => {
    if (!text) return null;
    
    // Split by words and non-words to preserve spacing and punctuation
    const parts = text.split(/([a-zA-Z0-9']+)/g);
    
    return parts.map((part, i) => {
      if (/[a-zA-Z0-9']+/.test(part)) {
        const count = syllable(part);
        let colorClass = 'text-white/90'; // default
        
        if (isSyllableColoringEnabled) {
          if (count === 1) colorClass = 'text-emerald-300';
          else if (count === 2) colorClass = 'text-blue-300';
          else if (count === 3) colorClass = 'text-purple-300';
          else if (count >= 4) colorClass = 'text-rose-300';
        }
        
        return <span key={i} className={colorClass}>{part}</span>;
      }
      return <span key={i} className="text-white/90">{part}</span>;
    });
  };

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

  const rhymeContext = getRhymeContext();

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
            <div className="h-4 w-px bg-white/20 mx-2" />
            <button 
              onClick={() => setIsProjectsModalOpen(true)}
              className="text-xs font-medium text-white/60 hover:text-white flex items-center gap-1.5 px-2 py-1 rounded-md hover:bg-white/10 transition-colors cursor-pointer"
            >
              <FolderOpen className="w-3.5 h-3.5" />
              Projects
            </button>
            {!currentProjectId && (
              <button 
                onClick={handleSaveProject}
                className="text-xs font-medium text-indigo-300 hover:text-indigo-200 flex items-center gap-1.5 px-2 py-1 rounded-md hover:bg-indigo-500/20 transition-colors cursor-pointer"
              >
                <Save className="w-3.5 h-3.5" />
                Save
              </button>
            )}
            {currentProjectId && (
              <span className="text-xs font-medium text-emerald-400/80 flex items-center gap-1.5 px-2 py-1">
                <Save className="w-3.5 h-3.5" />
                Saved
              </span>
            )}
          </div>
          <div className="flex flex-col items-end text-xs text-white/50">
            <span>{wordCount} words</span>
            <span>{syllable(lyrics)} syllables</span>
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
                <div className="relative w-full flex-1">
                  <div 
                    className={`lyrics-editor lyrics-backdrop w-full min-h-[50vh] ${!isSyllableColoringEnabled ? 'opacity-0' : ''}`}
                    aria-hidden="true"
                  >
                    {!lyrics && <span className="text-white/20">Start writing your lyrics here...</span>}
                    {renderColoredLyrics(lyrics)}
                    {/* Add a trailing newline space if the text ends with a newline to ensure the cursor can go to the next line visually */}
                    {lyrics.endsWith('\n') && <br />}
                  </div>
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
                    className={`lyrics-editor w-full overflow-hidden min-h-[50vh] ${isSyllableColoringEnabled ? 'lyrics-textarea' : ''}`}
                    spellCheck={false}
                  />
                </div>
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

      {/* Projects Modal */}
      <AnimatePresence>
        {isProjectsModalOpen && (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={() => setIsProjectsModalOpen(false)}
              className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            />
            <motion.div
              initial={{ opacity: 0, scale: 0.95, y: 20 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 20 }}
              className="relative w-full max-w-2xl bg-[#111] border border-white/10 rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[80vh]"
            >
              <div className="p-6 border-b border-white/10 flex items-center justify-between shrink-0">
                <h2 className="text-xl font-medium flex items-center gap-2">
                  <FolderOpen className="w-5 h-5 text-indigo-400" />
                  Song Projects
                </h2>
                <button 
                  onClick={() => setIsProjectsModalOpen(false)}
                  className="p-2 hover:bg-white/10 rounded-full transition-colors cursor-pointer"
                >
                  <X className="w-5 h-5 text-white/50 hover:text-white" />
                </button>
              </div>

              <div className="p-6 overflow-y-auto flex-1">
                <button
                  onClick={handleNewProject}
                  className="w-full mb-6 py-4 border-2 border-dashed border-white/20 hover:border-indigo-500/50 hover:bg-indigo-500/5 rounded-xl flex items-center justify-center gap-2 text-white/70 hover:text-white transition-all cursor-pointer"
                >
                  <Plus className="w-5 h-5" />
                  Create New Song
                </button>

                {projects.length === 0 ? (
                  <div className="text-center py-12 text-white/30">
                    <Music className="w-12 h-12 mx-auto mb-4 opacity-20" />
                    <p>No saved songs yet.</p>
                  </div>
                ) : (
                  <div className="grid gap-4">
                    {projects.sort((a, b) => b.updatedAt - a.updatedAt).map(project => (
                      <div 
                        key={project.id}
                        onClick={() => handleLoadProject(project)}
                        className={`p-4 rounded-xl border transition-all cursor-pointer group flex items-center justify-between ${
                          currentProjectId === project.id 
                            ? 'bg-indigo-600/10 border-indigo-500/50' 
                            : 'bg-white/5 border-white/5 hover:border-white/20 hover:bg-white/10'
                        }`}
                      >
                        <div className="min-w-0 flex-1 pr-4">
                          <h3 className="font-medium text-white truncate">
                            {project.title || 'Untitled Song'}
                          </h3>
                          <p className="text-sm text-white/40 truncate mt-1">
                            {new Date(project.updatedAt).toLocaleDateString()} • {project.lyrics.match(/\S+/g)?.length || 0} words
                          </p>
                        </div>
                        <button
                          onClick={(e) => handleDeleteProject(e, project.id)}
                          className="p-2 text-white/20 hover:text-red-400 hover:bg-red-400/10 rounded-lg transition-colors opacity-0 group-hover:opacity-100 cursor-pointer"
                          title="Delete Project"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </motion.div>
          </div>
        )}
      </AnimatePresence>
    </div>
  );
}
