import React, { useState, useRef, useEffect, useMemo, useCallback } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sparkles, Wand2, AlignLeft, Music, Loader2, ChevronRight, ChevronDown, FolderOpen, Save, Plus, Trash2, X, Check, LayoutTemplate } from 'lucide-react';
import { streamRhymeSuggestions } from './services/gemini';
import { syllable } from 'syllable';

interface SongProject {
  id: string;
  title: string;
  lyrics: string;
  theme: string;
  updatedAt: number;
}

const SONG_TEMPLATES = [
  {
    name: 'Pop Song',
    theme: 'Upbeat, catchy, relatable',
    lyrics: '[Verse 1]\n\n\n[Pre-Chorus]\n\n\n[Chorus]\n\n\n[Verse 2]\n\n\n[Pre-Chorus]\n\n\n[Chorus]\n\n\n[Bridge]\n\n\n[Chorus]\n\n\n[Outro]\n'
  },
  {
    name: 'Rap / Hip-Hop',
    theme: 'Storytelling, rhythm, flow',
    lyrics: '[Intro]\n\n\n[Verse 1]\n\n\n[Hook]\n\n\n[Verse 2]\n\n\n[Hook]\n\n\n[Bridge]\n\n\n[Hook]\n\n\n[Outro]\n'
  },
  {
    name: 'Country',
    theme: 'Storytelling, acoustic, heartfelt',
    lyrics: '[Verse 1]\n\n\n[Chorus]\n\n\n[Verse 2]\n\n\n[Chorus]\n\n\n[Bridge]\n\n\n[Chorus]\n\n\n[Outro]\n'
  },
  {
    name: 'Haiku',
    theme: 'Nature, concise, 5-7-5 syllables',
    lyrics: 'Line 1 (5 syllables):\n\nLine 2 (7 syllables):\n\nLine 3 (5 syllables):\n'
  }
];

const RHYME_MOTION = {
  feedback: 0.18,
  dismiss: 0.18,
  state: 0.26,
  dialog: 0.26,
  origin: 0.34,
  settle: 0.42,
} as const;

const RHYME_EASE_EMPHASIZED: [number, number, number, number] = [0.2, 0, 0, 1];


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
  const [isTemplatesModalOpen, setIsTemplatesModalOpen] = useState(false);
  const [isStartMenuOpen, setIsStartMenuOpen] = useState(() => {
    const hasProject = localStorage.getItem('lyricist-current-project');
    const hasTitle = localStorage.getItem('lyricist-title');
    const hasLyrics = localStorage.getItem('lyricist-lyrics');
    return !hasProject && !hasTitle && !hasLyrics;
  });
  const [saveStatus, setSaveStatus] = useState<'idle' | 'saving' | 'saved'>('idle');
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const rhymeOptions = ['Perfect Rhyme', 'Near Rhyme', 'Slant Rhyme'];

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

  // Auto-save current project (debounced)
  useEffect(() => {
    if (!title && !lyrics && !theme) {
      setSaveStatus('idle');
      return;
    }

    setSaveStatus('saving');

    const saveTimeout = setTimeout(() => {
      if (!currentProjectId) {
        const newId = crypto.randomUUID();
        const newProject: SongProject = {
          id: newId,
          title: title || 'Untitled Song',
          lyrics,
          theme,
          updatedAt: Date.now()
        };
        setProjects(prev => [newProject, ...prev]);
        setCurrentProjectId(newId);
      } else {
        setProjects(prev => prev.map(p =>
          p.id === currentProjectId
            ? { ...p, title: title || 'Untitled Song', lyrics, theme, updatedAt: Date.now() }
            : p
        ));
      }

      setSaveStatus('saved');
    }, 1000);

    return () => clearTimeout(saveTimeout);
  }, [title, lyrics, theme, currentProjectId]);

  const handleNewProject = () => {
    setTitle('');
    setLyrics('');
    setTheme('');
    setCurrentProjectId(null);
    setIsProjectsModalOpen(false);
    setIsStartMenuOpen(false);
  };

  const handleLoadProject = (project: SongProject) => {
    setTitle(project.title);
    setLyrics(project.lyrics);
    setTheme(project.theme);
    setCurrentProjectId(project.id);
    setIsProjectsModalOpen(false);
    setIsStartMenuOpen(false);
  };

  const handleDeleteProject = (e: React.MouseEvent, id: string) => {
    e.stopPropagation();
    setProjects(prev => prev.filter(p => p.id !== id));
    if (currentProjectId === id) {
      setCurrentProjectId(null);
    }
  };

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

  // Resize listener — mount once
  useEffect(() => {
    window.addEventListener('resize', adjustTextareaHeight);
    if (document.fonts) {
      document.fonts.ready.then(adjustTextareaHeight);
    }
    return () => {
      window.removeEventListener('resize', adjustTextareaHeight);
    };
  }, [adjustTextareaHeight]);

  // Auto-resize textarea on lyrics change
  useEffect(() => {
    adjustTextareaHeight();
  }, [lyrics, adjustTextareaHeight]);

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

  const suggestionsAbortRef = useRef<AbortController | null>(null);

  const handleGetSuggestions = async () => {
    if (!lyrics) return;
    const context = getRhymeContext();

    suggestionsAbortRef.current?.abort();
    const abort = new AbortController();
    suggestionsAbortRef.current = abort;
    setSuggestions([]);
    setIsLoading(true);

    try {
      for await (const line of streamRhymeSuggestions(
        theme,
        lyrics,
        context.targetLine,
        rhymeType,
        activeRhymeScheme,
        context.currentLetter,
        abort.signal,
      )) {
        if (abort.signal.aborted) break;
        setSuggestions(prev => [...prev, line]);
      }
    } catch (error) {
      if (!abort.signal.aborted) console.error(error);
    } finally {
      if (suggestionsAbortRef.current === abort) {
        suggestionsAbortRef.current = null;
        setIsLoading(false);
      }
    }
  };

  const cancelSuggestions = () => {
    suggestionsAbortRef.current?.abort();
    suggestionsAbortRef.current = null;
    setIsLoading(false);
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

  const rhymeContext = useMemo(() => getRhymeContext(), [lyrics, cursorPosition, activeRhymeScheme]);

  const wordCount = useMemo(() => lyrics.split(/\s+/).filter(w => w.length > 0).length, [lyrics]);
  const totalSyllables = useMemo(() => syllable(lyrics), [lyrics]);

  const coloredLyricsOverlay = useMemo(() => renderColoredLyrics(lyrics), [lyrics, isSyllableColoringEnabled]);

  return (
    <div className="min-h-screen bg-[#0a0a0a] text-white overflow-hidden relative flex flex-col md:flex-row">
      {/* Main Editor Area */}
      <main className="flex-1 flex flex-col h-screen relative w-full">
        {/* Header */}
        <motion.header 
          animate={{ y: isFocused ? '-100%' : 0, opacity: isFocused ? 0 : 1 }}
          transition={{ duration: RHYME_MOTION.origin, ease: RHYME_EASE_EMPHASIZED }}
          className="h-16 border-b border-white/10 flex items-center px-[var(--rhyme-space-screen-x)] justify-between shrink-0 glass-panel absolute top-0 w-full z-20 bg-[#0a0a0a]/90 backdrop-blur-md"
        >
          <div className="flex items-center gap-2 text-white/80">
            <Music className="w-5 h-5 text-indigo-400" />
            <h1 className="font-medium tracking-wide">Lyricist AI</h1>
            <div className="h-4 w-px bg-white/20 mx-2" />
            <button 
              onClick={() => setIsProjectsModalOpen(true)}
              className="rhyme-touch-target text-xs font-medium text-white/60 hover:text-white flex items-center gap-1.5 px-3 rounded-md hover:bg-white/10 transition-colors duration-[var(--rhyme-motion-feedback)] cursor-pointer"
            >
              <FolderOpen className="w-3.5 h-3.5" />
              Projects
            </button>
            {saveStatus === 'saving' && (
              <span role="status" aria-live="polite" className="text-xs font-medium text-white/50 flex items-center gap-1.5 px-2 py-1">
                <Loader2 className="w-3.5 h-3.5 animate-spin" />
                Saving...
              </span>
            )}
            {saveStatus === 'saved' && (
              <span role="status" aria-live="polite" className="text-xs font-medium text-emerald-400/80 flex items-center gap-1.5 px-2 py-1">
                <Check className="w-3.5 h-3.5" />
                Saved
              </span>
            )}
          </div>
          <div className="flex flex-col items-end text-xs text-white/50">
            <span>{wordCount} words</span>
            <span>{totalSyllables} syllables</span>
          </div>
        </motion.header>

        {/* Editor */}
        <motion.div 
          animate={{ paddingTop: isFocused ? '0' : '4rem' }}
          transition={{ duration: RHYME_MOTION.origin, ease: RHYME_EASE_EMPHASIZED }}
          className="flex-1 relative overflow-hidden flex flex-col"
        >
          <div className="absolute inset-0 pointer-events-none bg-gradient-to-b from-indigo-500/5 to-transparent opacity-50" />
          
          <div 
            className="flex-1 overflow-y-auto relative scroll-smooth"
            onScroll={(e) => setScrollY(e.currentTarget.scrollTop)}
          >
            <div className="max-w-[var(--rhyme-width-editor-max)] mx-auto min-h-full flex flex-col">
              {/* Sticky Title */}
              <div 
                className={`sticky top-0 z-10 bg-[#0a0a0a]/90 backdrop-blur-xl transition-[padding,border-color,box-shadow] duration-[var(--rhyme-motion-state)] px-[var(--rhyme-space-lg)] md:px-[var(--rhyme-space-xl)] ${
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
                  className={`bg-transparent font-serif font-bold outline-none placeholder:text-white/20 w-full transition-[font-size] duration-[var(--rhyme-motion-state)] ${
                    scrollY > 20 ? 'text-2xl md:text-3xl' : 'text-4xl md:text-5xl'
                  }`}
                />
              </div>

              {/* Lyrics Textarea */}
              <div className="px-[var(--rhyme-space-lg)] md:px-[var(--rhyme-space-xl)] pb-[var(--rhyme-space-editor-bottom-rest)] flex-1 flex flex-col">
                <div className="relative w-full flex-1">
                  <div 
                    className={`lyrics-editor lyrics-backdrop w-full min-h-[50vh] ${!isSyllableColoringEnabled ? 'opacity-0' : ''}`}
                    aria-hidden="true"
                  >
                    {!lyrics && <span className="text-white/20">Start writing your lyrics here...</span>}
                    {coloredLyricsOverlay}
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
        className={`rhyme-assistant-panel border-t md:border-t-0 md:border-l border-white/10 glass-panel flex flex-col fixed bottom-0 md:right-0 md:top-0 z-40 bg-[#0a0a0a]/95 backdrop-blur-2xl shadow-2xl shadow-black transition-transform duration-[var(--rhyme-motion-origin)] ease-[var(--rhyme-ease-emphasized)] ${
          isFocused ? 'translate-y-full md:translate-y-0 md:translate-x-full' : 'translate-y-0 md:translate-x-0'
        }`}
      >
        <div className="p-[var(--rhyme-space-assistant-panel)] border-b border-white/10">
          <button 
            onClick={() => setIsContextExpanded(!isContextExpanded)}
            aria-expanded={isContextExpanded}
            className="rhyme-touch-target w-full flex items-center justify-between text-left group cursor-pointer rounded-lg"
          >
            <h2 className="text-lg font-medium flex items-center gap-2">
              <Wand2 className="w-5 h-5 text-indigo-400" />
              Context & Theme
            </h2>
            <ChevronDown className={`w-5 h-5 text-white/40 transition-transform duration-[var(--rhyme-motion-state)] ${isContextExpanded ? 'rotate-180' : ''}`} />
          </button>
          
          <AnimatePresence initial={false}>
            {isContextExpanded && (
              <motion.div
                initial={{ height: 0, opacity: 0, marginTop: 0 }}
                animate={{ height: 'auto', opacity: 1, marginTop: 16 }}
                exit={{ height: 0, opacity: 0, marginTop: 0 }}
                transition={{ duration: RHYME_MOTION.state, ease: RHYME_EASE_EMPHASIZED }}
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

        <div className="flex-1 overflow-y-auto p-[var(--rhyme-space-assistant-panel)] flex flex-col gap-[var(--rhyme-space-assistant-panel)]">
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
                  aria-label="Rhyme scheme"
                  className="rhyme-touch-target bg-black/40 border border-white/10 rounded-lg px-3 text-xs text-white outline-none cursor-pointer"
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
                  className="rhyme-touch-target w-full bg-black/40 border border-white/10 rounded-lg px-3 text-sm text-white outline-none focus:border-indigo-500/50 transition-colors duration-[var(--rhyme-motion-feedback)]"
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
                    aria-pressed={rhymeType === option}
                    className={`rhyme-touch-target flex-1 text-xs font-medium rounded-lg transition-[background-color,color,box-shadow] duration-[var(--rhyme-motion-state)] ${
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
                aria-label="Toggle rhyme highlighting"
                aria-pressed={isHighlightEnabled}
                className="rhyme-touch-target flex items-center justify-center rounded-full cursor-pointer"
              >
                <span className={`w-10 h-5 rounded-full transition-colors duration-[var(--rhyme-motion-state)] relative ${
                  isHighlightEnabled ? 'bg-indigo-600' : 'bg-white/10'
                }`}>
                  <motion.span
                    className="w-4 h-4 bg-white rounded-full absolute top-0.5"
                    animate={{ left: isHighlightEnabled ? '1.25rem' : '0.125rem' }}
                    transition={{ duration: RHYME_MOTION.state, ease: RHYME_EASE_EMPHASIZED }}
                  />
                </span>
              </button>
            </div>

            <div className="flex items-center justify-between pt-2">
              <h3 className="text-sm font-medium text-white/70">Color Syllables</h3>
              <button
                onClick={() => setIsSyllableColoringEnabled(!isSyllableColoringEnabled)}
                aria-label="Toggle syllable coloring"
                aria-pressed={isSyllableColoringEnabled}
                className="rhyme-touch-target flex items-center justify-center rounded-full cursor-pointer"
              >
                <span className={`w-10 h-5 rounded-full transition-colors duration-[var(--rhyme-motion-state)] relative ${
                  isSyllableColoringEnabled ? 'bg-indigo-600' : 'bg-white/10'
                }`}>
                  <motion.span
                    className="w-4 h-4 bg-white rounded-full absolute top-0.5"
                    animate={{ left: isSyllableColoringEnabled ? '1.25rem' : '0.125rem' }}
                    transition={{ duration: RHYME_MOTION.state, ease: RHYME_EASE_EMPHASIZED }}
                  />
                </span>
              </button>
            </div>

            <button
              onClick={isLoading ? cancelSuggestions : handleGetSuggestions}
              disabled={!lyrics && !isLoading}
              aria-busy={isLoading}
              className="rhyme-touch-target w-full px-4 bg-indigo-600 hover:bg-indigo-500 disabled:bg-white/5 disabled:text-white/30 text-white rounded-xl font-medium transition-[background-color,color,box-shadow] duration-[var(--rhyme-motion-feedback)] flex items-center justify-center gap-2 shadow-lg shadow-indigo-500/20 disabled:shadow-none cursor-pointer"
            >
              {isLoading ? (
                <>
                  <Loader2 className="w-4 h-4 animate-spin" />
                  Stop
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
                transition={{ duration: RHYME_MOTION.state, ease: RHYME_EASE_EMPHASIZED }}
                className="space-y-3"
              >
                <h3 className="text-sm font-medium text-white/70">Suggestions</h3>
                <div className="space-y-2">
                  {suggestions.map((suggestion, idx) => (
                    <motion.button
                      key={`${suggestion}-${idx}`}
                      initial={{ opacity: 0, y: 8 }}
                      animate={{ opacity: 1, y: 0 }}
                      whileTap={{ scale: 0.99 }}
                      transition={{ duration: RHYME_MOTION.feedback, ease: RHYME_EASE_EMPHASIZED }}
                      onClick={() => insertSuggestion(suggestion)}
                      className="rhyme-touch-target w-full text-left p-4 rounded-xl bg-white/5 hover:bg-white/10 border border-white/5 hover:border-indigo-500/40 transition-[background-color,border-color,box-shadow] duration-[var(--rhyme-motion-feedback)] group flex items-start justify-between gap-4 cursor-pointer hover:shadow-lg hover:shadow-indigo-500/10"
                    >
                      <span className="font-serif text-white/90 leading-relaxed">
                        {renderSuggestionWithRhymeHighlight(suggestion)}
                      </span>
                      <div className="flex items-center gap-3 shrink-0 mt-1">
                        <span className="text-xs font-mono text-white/40 bg-white/5 px-2 py-1 rounded-md">
                          {syllable(suggestion)}
                        </span>
                        <ChevronRight className="w-4 h-4 text-white/20 group-hover:text-indigo-400 transition-[color,transform] duration-[var(--rhyme-motion-feedback)] group-hover:translate-x-1" />
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
            initial={{ opacity: 0, y: 20, scale: 0.96 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 20, scale: 0.96 }}
            transition={{ duration: RHYME_MOTION.origin, ease: RHYME_EASE_EMPHASIZED }}
            onClick={() => setIsFocused(false)}
            aria-label="Show assistant"
            className="rhyme-touch-target fixed bottom-8 right-8 z-30 bg-indigo-600 hover:bg-indigo-500 text-white px-5 rounded-full shadow-lg shadow-indigo-500/20 flex items-center gap-2 transition-[background-color,box-shadow] duration-[var(--rhyme-motion-feedback)] cursor-pointer"
          >
            <Wand2 className="w-4 h-4" />
            <span className="font-medium">Show Assistant</span>
          </motion.button>
        )}
      </AnimatePresence>

      {/* Projects Modal */}
      <AnimatePresence>
        {isProjectsModalOpen && (
          <div className="fixed inset-0 z-[110] flex items-center justify-center p-4">
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: RHYME_MOTION.dismiss, ease: RHYME_EASE_EMPHASIZED }}
              onClick={() => setIsProjectsModalOpen(false)}
              className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            />
            <motion.div
              initial={{ opacity: 0, scale: 0.96, y: 20 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.96, y: 20 }}
              transition={{ duration: RHYME_MOTION.dialog, ease: RHYME_EASE_EMPHASIZED }}
              className="relative w-full max-w-[var(--rhyme-width-modal)] bg-[#111] border border-white/10 rounded-[var(--rhyme-radius-sheet)] shadow-2xl overflow-hidden flex flex-col max-h-[80vh]"
            >
              <div className="p-[var(--rhyme-space-modal)] border-b border-white/10 flex items-center justify-between shrink-0">
                <h2 className="text-xl font-medium flex items-center gap-2">
                  <FolderOpen className="w-5 h-5 text-indigo-400" />
                  Song Projects
                </h2>
                <button 
                  onClick={() => setIsProjectsModalOpen(false)}
                  aria-label="Close projects"
                  className="rhyme-touch-target flex items-center justify-center hover:bg-white/10 rounded-full transition-colors duration-[var(--rhyme-motion-feedback)] cursor-pointer"
                >
                  <X className="w-5 h-5 text-white/50 hover:text-white" />
                </button>
              </div>

              <div className="p-[var(--rhyme-space-modal)] overflow-y-auto flex-1">
                <button
                  onClick={handleNewProject}
                  className="rhyme-touch-target w-full mb-6 px-4 border-2 border-dashed border-white/20 hover:border-indigo-500/50 hover:bg-indigo-500/5 rounded-xl flex items-center justify-center gap-2 text-white/70 hover:text-white transition-[background-color,border-color,color] duration-[var(--rhyme-motion-feedback)] cursor-pointer"
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
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            handleLoadProject(project);
                          }
                        }}
                        className={`min-h-[var(--rhyme-touch-target)] p-4 rounded-xl border transition-[background-color,border-color] duration-[var(--rhyme-motion-feedback)] cursor-pointer group flex items-center justify-between ${
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
                            {new Date(project.updatedAt).toLocaleDateString()} • {project.lyrics.split(/\s+/).filter(w => w.length > 0).length} words
                          </p>
                        </div>
                        <button
                          onClick={(e) => handleDeleteProject(e, project.id)}
                          className="rhyme-touch-target flex items-center justify-center text-white/30 hover:text-red-400 hover:bg-red-400/10 rounded-lg transition-[background-color,color,opacity] duration-[var(--rhyme-motion-feedback)] opacity-100 md:opacity-0 md:group-hover:opacity-100 cursor-pointer"
                          aria-label={`Delete ${project.title || 'Untitled Song'}`}
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

      {/* Templates Modal */}
      <AnimatePresence>
        {isTemplatesModalOpen && (
          <div className="fixed inset-0 z-[120] flex items-center justify-center p-4">
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: RHYME_MOTION.dismiss, ease: RHYME_EASE_EMPHASIZED }}
              onClick={() => setIsTemplatesModalOpen(false)}
              className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            />
            <motion.div
              initial={{ opacity: 0, scale: 0.96, y: 20 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.96, y: 20 }}
              transition={{ duration: RHYME_MOTION.dialog, ease: RHYME_EASE_EMPHASIZED }}
              className="relative w-full max-w-[var(--rhyme-width-modal)] bg-[#111] border border-white/10 rounded-[var(--rhyme-radius-sheet)] shadow-2xl overflow-hidden flex flex-col max-h-[80vh]"
            >
              <div className="p-[var(--rhyme-space-modal)] border-b border-white/10 flex items-center justify-between shrink-0">
                <h2 className="text-xl font-medium flex items-center gap-2">
                  <LayoutTemplate className="w-5 h-5 text-indigo-400" />
                  Choose a Template
                </h2>
                <button 
                  onClick={() => setIsTemplatesModalOpen(false)}
                  aria-label="Close templates"
                  className="rhyme-touch-target flex items-center justify-center hover:bg-white/10 rounded-full transition-colors duration-[var(--rhyme-motion-feedback)] cursor-pointer"
                >
                  <X className="w-5 h-5 text-white/50 hover:text-white" />
                </button>
              </div>

              <div className="p-[var(--rhyme-space-modal)] overflow-y-auto flex-1">
                <div className="grid gap-4 md:grid-cols-2">
                  {SONG_TEMPLATES.map((template, idx) => (
                    <button
                      key={idx}
                      onClick={() => {
                        setTitle(`Untitled ${template.name}`);
                        setTheme(template.theme);
                        setLyrics(template.lyrics);
                        setCurrentProjectId(null);
                        setIsTemplatesModalOpen(false);
                        setIsStartMenuOpen(false);
                      }}
                      className="min-h-[var(--rhyme-touch-target)] text-left p-[var(--rhyme-space-modal)] rounded-xl border bg-white/5 border-white/5 hover:border-indigo-500/50 hover:bg-white/10 transition-[background-color,border-color] duration-[var(--rhyme-motion-feedback)] cursor-pointer group"
                    >
                      <h3 className="font-medium text-lg text-white mb-2 group-hover:text-indigo-300 transition-colors">
                        {template.name}
                      </h3>
                      <p className="text-sm text-white/40">
                        {template.theme}
                      </p>
                    </button>
                  ))}
                </div>
              </div>
            </motion.div>
          </div>
        )}
      </AnimatePresence>

      {/* Start Menu */}
      <AnimatePresence>
        {isStartMenuOpen && (
          <div className="fixed inset-0 z-[100] flex items-center justify-center p-4 bg-[#0a0a0a]">
            {/* Background effects */}
            <div className="absolute inset-0 pointer-events-none bg-gradient-to-b from-indigo-500/10 to-transparent opacity-50" />
            
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -20 }}
              transition={{ duration: RHYME_MOTION.dialog, ease: RHYME_EASE_EMPHASIZED }}
              className="relative w-full max-w-[var(--rhyme-width-start)] flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-indigo-500/20 rounded-full flex items-center justify-center mb-8 border border-indigo-500/30 shadow-[0_0_40px_rgba(99,102,241,0.2)]">
                <Music className="w-10 h-10 text-indigo-400" />
              </div>
              
              <h1 className="text-4xl md:text-6xl font-serif font-bold mb-4 tracking-tight">
                Welcome to <span className="text-transparent bg-clip-text bg-gradient-to-r from-indigo-400 to-purple-400">Lyricist AI</span>
              </h1>
              <p className="text-lg text-white/50 mb-12 max-w-xl">
                Your intelligent songwriting companion. Start from scratch, load an existing masterpiece, or kickstart your creativity with a template.
              </p>

              <div className="grid grid-cols-1 md:grid-cols-3 gap-[var(--rhyme-space-lg)] w-full">
                <button
                  onClick={() => {
                    setIsStartMenuOpen(false);
                    handleNewProject();
                  }}
                  className="rhyme-touch-target group relative p-8 rounded-[var(--rhyme-radius-sheet)] bg-white/5 border border-white/10 hover:border-indigo-500/50 hover:bg-white/10 transition-[background-color,border-color] duration-[var(--rhyme-motion-feedback)] cursor-pointer flex flex-col items-center text-center overflow-hidden"
                >
                  <div className="absolute inset-0 bg-gradient-to-b from-indigo-500/0 to-indigo-500/0 group-hover:from-indigo-500/10 group-hover:to-transparent transition-colors duration-[var(--rhyme-motion-feedback)]" />
                  <Plus className="w-8 h-8 text-white/70 group-hover:text-indigo-400 mb-4 transition-colors" />
                  <h3 className="text-xl font-medium mb-2">New Song</h3>
                  <p className="text-sm text-white/40">Start with a blank canvas</p>
                </button>

                <button
                  onClick={() => {
                    setIsProjectsModalOpen(true);
                  }}
                  className="rhyme-touch-target group relative p-8 rounded-[var(--rhyme-radius-sheet)] bg-white/5 border border-white/10 hover:border-indigo-500/50 hover:bg-white/10 transition-[background-color,border-color] duration-[var(--rhyme-motion-feedback)] cursor-pointer flex flex-col items-center text-center overflow-hidden"
                >
                  <div className="absolute inset-0 bg-gradient-to-b from-indigo-500/0 to-indigo-500/0 group-hover:from-indigo-500/10 group-hover:to-transparent transition-colors duration-[var(--rhyme-motion-feedback)]" />
                  <FolderOpen className="w-8 h-8 text-white/70 group-hover:text-indigo-400 mb-4 transition-colors" />
                  <h3 className="text-xl font-medium mb-2">Load Song</h3>
                  <p className="text-sm text-white/40">Continue where you left off</p>
                </button>

                <button
                  onClick={() => {
                    setIsTemplatesModalOpen(true);
                  }}
                  className="rhyme-touch-target group relative p-8 rounded-[var(--rhyme-radius-sheet)] bg-white/5 border border-white/10 hover:border-indigo-500/50 hover:bg-white/10 transition-[background-color,border-color] duration-[var(--rhyme-motion-feedback)] cursor-pointer flex flex-col items-center text-center overflow-hidden"
                >
                  <div className="absolute inset-0 bg-gradient-to-b from-indigo-500/0 to-indigo-500/0 group-hover:from-indigo-500/10 group-hover:to-transparent transition-colors duration-[var(--rhyme-motion-feedback)]" />
                  <LayoutTemplate className="w-8 h-8 text-white/70 group-hover:text-indigo-400 mb-4 transition-colors" />
                  <h3 className="text-xl font-medium mb-2">Song Templates</h3>
                  <p className="text-sm text-white/40">Start with a structured layout</p>
                </button>
              </div>
            </motion.div>
          </div>
        )}
      </AnimatePresence>
    </div>
  );
}
