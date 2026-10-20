package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeType
import java.io.InputStream

data class WordProsody(
    val word: String,
    val normalized: String,
    val syllableCount: Int,
    val stressPattern: List<Int>,
    val ipa: String,
    val isFallback: Boolean
)

data class LineProsody(
    val words: List<WordProsody>,
    val syllableCount: Int,
    val stressPattern: List<Int>,
    val feet: String,
    val ipa: String
)

data class RhymeMatches(
    val perfect: List<String>,
    val near: List<String>,
    val multi: List<String>,
    val slant: List<String> = emptyList()
) {
    val isEmpty: Boolean get() = perfect.isEmpty() && near.isEmpty() && multi.isEmpty() && slant.isEmpty()

    companion object {
        val EMPTY = RhymeMatches(emptyList(), emptyList(), emptyList())
    }
}

data class RhymeTail(val vowel: String, val coda: List<String>)

/** [profiles] holds every pronunciation of [word], shared by all its entries. */
private class RhymeTailEntry(val word: String, val tail: RhymeTail, val profiles: List<ProsodyAnalyzer.RhymeProfile>)

class PronunciationDictionary private constructor(
    private val entries: Map<String, List<List<String>>>
) {
    fun pronunciations(normalizedWord: String): List<List<String>> = entries[normalizedWord].orEmpty()

    val wordCount: Int get() = entries.size

    fun forEachEntry(action: (String, List<List<String>>) -> Unit) {
        entries.forEach { (word, variants) -> action(word, variants) }
    }

    companion object {
        @Volatile
        private var sharedDictionary = PronunciationDictionary(emptyMap())

        val shared: PronunciationDictionary
            get() = sharedDictionary

        fun initialize(inputStream: InputStream) {
            sharedDictionary = inputStream.bufferedReader().useLines { lines ->
                fromLines(lines).also { dictionary ->
                    check(dictionary.entries.isNotEmpty()) { "Pronunciation dictionary is empty" }
                }
            }
        }

        fun fromLines(lines: Sequence<String>): PronunciationDictionary {
            val parsed = mutableMapOf<String, List<List<String>>>()
            lines.forEach { row ->
                if (row.isBlank() || row.startsWith("#")) return@forEach
                val tabIndex = row.indexOf('\t')
                if (tabIndex <= 0) return@forEach

                val word = row.substring(0, tabIndex)
                val variants = row.substring(tabIndex + 1)
                    .split('|')
                    .map { variant -> variant.trim().split(Regex("\\s+")).filter { it.isNotBlank() } }
                    .filter { it.isNotEmpty() }

                if (variants.isNotEmpty()) parsed[word] = variants
            }
            return PronunciationDictionary(parsed)
        }
    }
}

object ProsodyAnalyzer {
    private val wordPattern = LyricTokenizer.wordPattern
    private val vowels = setOf(
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY",
        "OW", "OY", "UH", "UW"
    )
    private val stopwords = setOf(
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were",
        "be", "to", "of", "in", "on", "at", "by", "for", "with", "as",
        "it", "its", "this", "that", "these", "those", "i", "you", "he",
        "she", "we", "they", "them", "his", "her", "our", "their", "my",
        "do", "does", "did", "have", "has", "had", "not", "if", "so", "no"
    )
    /** Grammatical words; identical list on iOS. */
    private val functionWords = stopwords + setOf(
        "me", "mine", "myself", "your", "yours", "yourself", "yourselves", "him", "himself",
        "hers", "herself", "itself", "us", "ours", "ourselves", "theirs", "themselves",
        "who", "whom", "whose", "which", "what", "whatever", "whoever", "whichever",
        "when", "whenever", "where", "wherever", "why", "how", "however", "whether",
        "while", "whereas", "though", "although", "because", "unless", "then", "than",
        "yet", "nor", "there", "here", "some", "any", "each", "every", "either", "neither",
        "both", "all", "such", "more", "most", "much", "many", "few", "less", "least",
        "into", "onto", "from", "upon", "unto", "via", "per", "among", "amongst", "toward",
        "towards", "during", "until", "till", "since", "despite", "except", "against",
        "between", "through", "within", "without", "across", "am", "been", "being",
        "having", "will", "would", "shall", "should", "can", "could", "may", "might",
        "must", "ought", "just", "very", "too", "also", "really", "quite", "rather", "else",
        "i'm", "you're", "he's", "she's", "it's", "we're", "they're", "i've", "you've",
        "we've", "they've", "i'd", "you'd", "he'd", "she'd", "we'd", "they'd", "i'll",
        "you'll", "he'll", "she'll", "we'll", "they'll", "isn't", "aren't", "wasn't",
        "weren't", "don't", "doesn't", "didn't", "won't", "wouldn't", "can't", "couldn't",
        "shouldn't", "that's", "there's", "what's", "who's", "let's", "ain't"
    )
    private val substitutions = listOf(
        "tion" to "shn",
        "sion" to "shn",
        "cion" to "shn",
        "cian" to "shn",
        "tial" to "shl",
        "cial" to "shl",
        "ough" to "of",
        "augh" to "af",
        "eigh" to "ay",
        "ight" to "ite",
        "ph" to "f",
        "ck" to "k",
        "qu" to "kw",
        "wh" to "w",
        "x" to "ks"
    )
    private val ipaByPhone = mapOf(
        "AA" to "ɑ",
        "AE" to "æ",
        "AH" to "ʌ",
        "AO" to "ɔ",
        "AW" to "aʊ",
        "AY" to "aɪ",
        "EH" to "ɛ",
        "ER" to "ɝ",
        "EY" to "eɪ",
        "IH" to "ɪ",
        "IY" to "i",
        "OW" to "oʊ",
        "OY" to "ɔɪ",
        "UH" to "ʊ",
        "UW" to "u",
        "B" to "b",
        "CH" to "tʃ",
        "D" to "d",
        "DH" to "ð",
        "F" to "f",
        "G" to "ɡ",
        "HH" to "h",
        "JH" to "dʒ",
        "K" to "k",
        "L" to "l",
        "M" to "m",
        "N" to "n",
        "NG" to "ŋ",
        "P" to "p",
        "R" to "r",
        "S" to "s",
        "SH" to "ʃ",
        "T" to "t",
        "TH" to "θ",
        "V" to "v",
        "W" to "w",
        "Y" to "j",
        "Z" to "z",
        "ZH" to "ʒ"
    )

    fun analyzeWord(
        word: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): WordProsody {
        val normalized = normalizeWord(word)
        if (normalized.isEmpty()) {
            return WordProsody(word, normalized, 0, emptyList(), "", isFallback = true)
        }

        val variants = dictionary.pronunciations(normalized)
        if (variants.isEmpty()) {
            val stressPattern = fallbackStressPattern(normalized)
            return WordProsody(
                word = word,
                normalized = normalized,
                syllableCount = stressPattern.size,
                stressPattern = stressPattern,
                ipa = "",
                isFallback = true
            )
        }

        val phones = variants.first()
        val stressPattern = stressPatternForPhones(phones)
        return WordProsody(
            word = word,
            normalized = normalized,
            syllableCount = stressPattern.size,
            stressPattern = stressPattern,
            ipa = ipaForPhones(phones),
            isFallback = false
        )
    }

    fun analyzeLine(
        text: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): LineProsody {
        val words = wordPattern.findAll(text).map { analyzeWord(it.value, dictionary) }.toList()
        val stresses = words.flatMap { it.stressPattern }
        return LineProsody(
            words = words,
            syllableCount = words.sumOf { it.syllableCount },
            stressPattern = stresses,
            feet = metricFeet(stresses),
            ipa = words.mapNotNull { it.ipa.ifBlank { it.normalized }.takeIf(String::isNotBlank) }.joinToString(" ")
        )
    }

    fun countWord(word: String): Int = analyzeWord(word).syllableCount

    fun countText(text: String): Int = analyzeLine(text).syllableCount

    fun rhymeKeys(
        word: String,
        maxDepth: Int = 2,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        val normalized = normalizeWord(word)
        if (normalized.length < 2 || normalized in stopwords) return emptyList()

        val variants = dictionary.pronunciations(normalized)
        if (variants.isEmpty()) return fallbackRhymeKeys(normalized, maxDepth)

        return variants
            .flatMap { rhymeKeysForPhones(it, maxDepth) }
            .distinct()
    }

    @Volatile private var indexBuiltFor: PronunciationDictionary? = null
    @Volatile private var perfectByKey: Map<String, List<String>> = emptyMap()
    @Volatile private var multiByKey: Map<String, List<String>> = emptyMap()
    @Volatile private var tailsByVowel: Map<String, List<RhymeTailEntry>> = emptyMap()
    @Volatile private var tailsByCoda: Map<String, List<RhymeTailEntry>> = emptyMap()
    @Volatile private var weakTailsByKey: Map<String, List<RhymeTailEntry>> = emptyMap()
    private val indexLock = Any()

    fun findRhymes(
        word: String,
        perfectLimit: Int = 60,
        nearLimit: Int = 30,
        multiLimit: Int = 30,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared,
        wordFrequency: WordFrequency = WordFrequency.shared
    ): RhymeMatches {
        val normalized = normalizeWord(word)
        if (normalized.length < 2 || normalized in stopwords) return RhymeMatches.EMPTY
        if (dictionary.wordCount == 0) return RhymeMatches.EMPTY

        val keys = rhymeKeys(word, maxDepth = 2, dictionary = dictionary)
        if (keys.isEmpty()) return RhymeMatches.EMPTY
        val k0 = keys[0]
        val k1 = keys.getOrNull(1)

        ensureIndex(dictionary)
        val perfectAll = (perfectByKey[k0] ?: emptyList()).filter { it != normalized }
        val multiAll = if (k1 != null) {
            (multiByKey[k1] ?: emptyList()).filter { it != normalized && it !in perfectAll }
        } else emptyList()
        val exclude = perfectAll.toHashSet().apply { addAll(multiAll) }

        val near: List<String>
        val slant: List<String>
        // Every pronunciation of the target, so "abuse" (/s/ and /z/) is
        // classified the same way rhymeRelation verifies a returned line.
        val targetProfiles = dictionary.pronunciations(normalized).mapNotNull(::rhymeProfile)
        if (targetProfiles.isEmpty() || rhymeTail(word, dictionary) == null) {
            near = emptyList()
            slant = emptyList()
        } else {
            // Every word that can stand in a near or slant relation to any target
            // pronunciation: the same stressed vowel, the same coda, or a
            // stress-shifted tail.
            val pool = HashMap<String, List<RhymeProfile>>()
            for (tail in targetProfiles.map { it.tail }.toSet()) {
                tailsByVowel[tail.vowel].orEmpty().forEach { pool[it.word] = it.profiles }
                if (tail.coda.isNotEmpty()) tailsByCoda[codaKey(tail.coda)].orEmpty().forEach { pool[it.word] = it.profiles }
                weakTailsByKey[codaKey(listOf(tail.vowel) + tail.coda)].orEmpty().forEach { pool[it.word] = it.profiles }
                tail.coda.filter(::isVowelPhone).toSet().forEach { vowel ->
                    if (vowel != tail.vowel) tailsByVowel[vowel].orEmpty().forEach { pool[it.word] = it.profiles }
                }
            }

            // Each word takes its closest relation over every pronunciation pair;
            // a word that is perfect under any pairing is in neither list.
            val best = HashMap<String, TailRelation>()
            for ((candidate, profiles) in pool) {
                if (candidate == normalized || candidate in exclude || isInflection(candidate, normalized) ||
                    !isSpelledAsWord(candidate)
                ) continue
                val relation = bestRelation(targetProfiles, profiles) ?: continue
                if (relation.type != RhymeType.PERFECT) best[candidate] = relation
            }
            near = songwriterOrder(best.filterValues { it.type == RhymeType.NEAR }, wordFrequency)
            slant = songwriterOrder(best.filterValues { it.type == RhymeType.SLANT }, wordFrequency)
        }

        // Rank each pool before the limit cut, so both candidateEndWords and
        // the rhyme inspector surface familiar words rather than
        // dictionary-hash-order obscurities.
        return RhymeMatches(
            perfect = wordFrequency.sortByFrequency(perfectAll).take(perfectLimit),
            near = near.take(nearLimit),
            multi = wordFrequency.sortByFrequency(multiAll).take(multiLimit),
            slant = slant.take(nearLimit)
        )
    }

    /** Near and slant order for a songwriter: content words before function
     *  words, closer relations first, then common before rare, then spelling
     *  so ties are identical on every platform. */
    private fun songwriterOrder(relations: Map<String, TailRelation>, wordFrequency: WordFrequency): List<String> =
        relations.entries
            .sortedWith(
                compareBy<Map.Entry<String, TailRelation>> { if (isFunctionWord(it.key)) 1 else 0 }
                    .thenBy { it.value.tier }
                    .thenBy { wordFrequency.rankOf(it.key) }
                    .thenBy { it.key }
            )
            .map { it.key }

    private fun codaKey(coda: List<String>): String = coda.joinToString(" ")

    private fun ensureIndex(dictionary: PronunciationDictionary) {
        if (indexBuiltFor === dictionary) return
        synchronized(indexLock) {
            if (indexBuiltFor === dictionary) return
            val perfectBuild = HashMap<String, MutableList<String>>(32_768)
            val multiBuild = HashMap<String, MutableList<String>>(32_768)
            val vowelBuild = HashMap<String, MutableList<RhymeTailEntry>>(64)
            val codaBuild = HashMap<String, MutableList<RhymeTailEntry>>(4_096)
            val weakBuild = HashMap<String, MutableList<RhymeTailEntry>>(4_096)
            dictionary.forEachEntry { word, variants ->
                if (word.length < 2) return@forEachEntry
                val isStopword = word in stopwords
                val seenK0 = HashSet<String>(2)
                val seenK1 = HashSet<String>(2)
                val profiles = ArrayList<RhymeProfile>(variants.size)
                for (phones in variants) {
                    val ks = rhymeKeysForPhones(phones, maxDepth = 2)
                    val k0 = ks.getOrNull(0) ?: continue
                    rhymeTailForPhones(phones)?.let { profiles += RhymeProfile(k0, ks.getOrNull(1), it) }
                    if (isStopword) continue
                    if (seenK0.add(k0)) {
                        perfectBuild.getOrPut(k0) { ArrayList(8) }.add(word)
                    }
                    val k1 = ks.getOrNull(1) ?: continue
                    if (seenK1.add(k1)) {
                        multiBuild.getOrPut(k1) { ArrayList(4) }.add(word)
                    }
                }
                for (tail in profiles.map { it.tail }.distinct()) {
                    val entry = RhymeTailEntry(word, tail, profiles)
                    vowelBuild.getOrPut(tail.vowel) { ArrayList(256) }.add(entry)
                    if (tail.coda.isNotEmpty()) {
                        codaBuild.getOrPut(codaKey(tail.coda)) { ArrayList(8) }.add(entry)
                    }
                    // Unstressed syllables after the stress ("happy" ends in an
                    // unstressed IY), for stress-shifted near rhymes.
                    tail.coda.forEachIndexed { index, phone ->
                        if (isVowelPhone(phone)) {
                            weakBuild.getOrPut(codaKey(tail.coda.drop(index))) { ArrayList(8) }.add(entry)
                        }
                    }
                }
            }
            perfectByKey = perfectBuild
            multiByKey = multiBuild
            tailsByVowel = vowelBuild
            tailsByCoda = codaBuild
            weakTailsByKey = weakBuild
            indexBuiltFor = dictionary
        }
    }

    /** Stressed vowel and everything after it, from the first pronunciation. */
    fun rhymeTail(
        word: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): RhymeTail? {
        val normalized = normalizeWord(word)
        if (normalized.length < 2 || normalized in stopwords) return null
        return dictionary.pronunciations(normalized).firstOrNull()?.let(::rhymeTailForPhones)
    }

    /** Pairwise relation over every pronunciation of both words; mirrors iOS `rhymeRelation`. */
    fun rhymeRelation(
        candidateWord: String,
        targetWord: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): RhymeType? {
        val candidate = normalizeWord(candidateWord)
        val target = normalizeWord(targetWord)
        if (candidate == target) return null
        return bestRelation(
            dictionary.pronunciations(target).mapNotNull(::rhymeProfile),
            dictionary.pronunciations(candidate).mapNotNull(::rhymeProfile)
        )?.type
    }

    /** One pronunciation's rhyme keys and tail. */
    class RhymeProfile(val key: String, val multiKey: String?, val tail: RhymeTail)

    private fun rhymeProfile(phones: List<String>): RhymeProfile? {
        val keys = rhymeKeysForPhones(phones, maxDepth = 2)
        val key = keys.firstOrNull() ?: return null
        val tail = rhymeTailForPhones(phones) ?: return null
        return RhymeProfile(key, keys.getOrNull(1), tail)
    }

    /** The closest relation over every target x candidate pronunciation, with
     *  Perfect > Near > Slant. The rhyme lists and [rhymeRelation] both use it,
     *  so a listed word always verifies as its list's relation. */
    fun bestRelation(target: List<RhymeProfile>, candidate: List<RhymeProfile>): TailRelation? {
        var best: TailRelation? = null
        for (targetProfile in target) {
            for (candidateProfile in candidate) {
                if (candidateProfile.key == targetProfile.key ||
                    (targetProfile.multiKey != null && candidateProfile.multiKey == targetProfile.multiKey)
                ) return TailRelation(RhymeType.PERFECT, 0)
                val relation = tailRelation(targetProfile.tail, candidateProfile.tail) ?: continue
                if (best == null || relation.rank < best.rank) best = relation
            }
        }
        return best
    }

    /** How a candidate's rhyme tail relates to the target's when the two are
     *  not a perfect rhyme. [tier] orders near rhymes from closest (1) to
     *  loosest (2); slant rhymes are all tier 1. */
    data class TailRelation(val type: RhymeType, val tier: Int) {
        /** Lower is better: perfect, then near, then slant, then by tier. */
        val rank: Int get() = when (type) {
            RhymeType.PERFECT -> tier
            RhymeType.NEAR -> 10 + tier
            RhymeType.SLANT -> 20 + tier
        }
    }

    /**
     * Near and slant rhymes as songwriters classify them (family, additive and
     * subtractive rhymes; assonance; consonance). Identical on iOS
     * (`ProsodyAnalyzer.swift`).
     *
     * Near, tier 1: same stressed vowel, and the codas differ by one consonant
     * from the same family (plosives, fricatives, nasals) or by one added or
     * dropped consonant ("night"/"ride", "home"/"phone", "chair"/"stairs").
     * Near, tier 2: one coda adds an unstressed syllable to the other
     * ("chair"/"caring"), or the stress falls differently on the same tail
     * ("free"/"happy").
     * Slant: consonance, a different stressed vowel before an identical coda
     * ("chair"/"door"), or assonance, the same stressed vowel and syllable
     * shape before unrelated consonants ("night"/"time").
     *
     * A vowel followed by R is treated as its own vowel ("chair" is not
     * assonant with "then"), as it is in American English.
     */
    fun tailRelation(target: RhymeTail, candidate: RhymeTail): TailRelation? {
        if (target == candidate) return null
        if (target.vowel == candidate.vowel) {
            val targetRColored = target.coda.firstOrNull() == "R"
            val candidateRColored = candidate.coda.firstOrNull() == "R"
            if (targetRColored == candidateRColored) {
                val targetRest = if (targetRColored) target.coda.drop(1) else target.coda
                val candidateRest = if (candidateRColored) candidate.coda.drop(1) else candidate.coda
                if (isCloseCodaEdit(targetRest, candidateRest)) return TailRelation(RhymeType.NEAR, 1)
                if (addsUnstressedSyllable(targetRest, candidateRest)) return TailRelation(RhymeType.NEAR, 2)
                if (isStressShift(target, candidate)) return TailRelation(RhymeType.NEAR, 2)
                if (targetRest.filter(::isVowelPhone) == candidateRest.filter(::isVowelPhone)) {
                    return TailRelation(RhymeType.SLANT, 1)
                }
            }
            return if (isStressShift(target, candidate)) TailRelation(RhymeType.NEAR, 2) else null
        }
        if (isStressShift(target, candidate)) return TailRelation(RhymeType.NEAR, 2)
        if (target.coda.isNotEmpty() && target.coda == candidate.coda) return TailRelation(RhymeType.SLANT, 1)
        return null
    }

    fun isVowelPhone(phone: String): Boolean = phone in vowels

    /** Grammatical words rank after content words in near and slant lists. */
    fun isFunctionWord(normalizedWord: String): Boolean = normalizedWord in functionWords

    /** True when [word] is just [base] with an inflection ("chairs", "homing"),
     *  which is no help to a songwriter looking for a new ending. */
    fun isInflection(word: String, base: String): Boolean {
        if (base.isEmpty() || word.length <= base.length) return false
        val stems = if (base.endsWith("e")) listOf(base, base.dropLast(1)) else listOf(base)
        return stems.any { stem -> word.startsWith(stem) && word.substring(stem.length) in inflectionSuffixes }
    }

    /** Rejects abbreviations spelled without a vowel letter ("mr", "st"). */
    fun isSpelledAsWord(word: String): Boolean = word.any { it in "aeiouy" }

    private val inflectionSuffixes = setOf("s", "es", "'s", "ed", "ing")

    /** Same family: plosives, fricatives (with affricates), nasals. */
    private val consonantFamilies = listOf(
        setOf("P", "B", "T", "D", "K", "G"),
        setOf("F", "V", "TH", "DH", "S", "Z", "SH", "ZH", "CH", "JH"),
        setOf("M", "N", "NG")
    )

    private fun isCloseConsonant(lhs: String, rhs: String): Boolean =
        consonantFamilies.any { lhs in it && rhs in it }

    /** One family substitution, or one consonant added or dropped. */
    private fun isCloseCodaEdit(lhs: List<String>, rhs: List<String>): Boolean {
        if (lhs.size == rhs.size) {
            val differences = lhs.zip(rhs).filter { it.first != it.second }
            if (differences.size != 1) return false
            val (a, b) = differences.first()
            return !isVowelPhone(a) && !isVowelPhone(b) && isCloseConsonant(a, b)
        }
        if (kotlin.math.abs(lhs.size - rhs.size) != 1) return false
        val shorter = if (lhs.size < rhs.size) lhs else rhs
        val longer = if (lhs.size < rhs.size) rhs else lhs
        return longer.indices.any { index ->
            !isVowelPhone(longer[index]) && longer.take(index) + longer.drop(index + 1) == shorter
        }
    }

    /** The longer coda is the shorter plus exactly one more (unstressed) syllable. */
    private fun addsUnstressedSyllable(lhs: List<String>, rhs: List<String>): Boolean {
        if (lhs.size == rhs.size) return false
        val shorter = if (lhs.size < rhs.size) lhs else rhs
        val longer = if (lhs.size < rhs.size) rhs else lhs
        if (longer.take(shorter.size) != shorter) return false
        return longer.drop(shorter.size).count(::isVowelPhone) == 1
    }

    /** One word's stressed tail is the other's unstressed ending ("free"/"happy"). */
    private fun isStressShift(lhs: RhymeTail, rhs: RhymeTail): Boolean {
        val lhsFull = listOf(lhs.vowel) + lhs.coda
        val rhsFull = listOf(rhs.vowel) + rhs.coda
        return (rhs.coda.size >= lhsFull.size && rhs.coda.takeLast(lhsFull.size) == lhsFull) ||
            (lhs.coda.size >= rhsFull.size && lhs.coda.takeLast(rhsFull.size) == rhsFull)
    }

    private fun rhymeTailForPhones(phones: List<String>): RhymeTail? {
        val vowelIndexes = phones.indices.filter { basePhone(phones[it]) in vowels }
        if (vowelIndexes.isEmpty()) return null
        val stressed = vowelIndexes.filter { (stressForPhone(phones[it]) ?: 0) > 0 }
        val vowelIndex = (stressed.ifEmpty { vowelIndexes }).last()
        return RhymeTail(
            vowel = basePhone(phones[vowelIndex]),
            coda = phones.drop(vowelIndex + 1).map(::basePhone)
        )
    }

    fun metricFeet(stressPattern: List<Int>): String {
        return stressPattern
            .map { stress -> if (stress == 0) "da" else "ˈDA" }
            .chunked(2)
            .joinToString(" | ") { it.joinToString(" ") }
    }

    fun normalizeWord(word: String): String {
        return word.lowercase()
            .filter { it in 'a'..'z' || it == '\'' }
            .trim('\'')
    }

    private fun basePhone(phone: String): String = phone.replace(Regex("[0-2]$"), "")

    private fun stressForPhone(phone: String): Int? {
        val last = phone.lastOrNull() ?: return null
        return last.digitToIntOrNull()?.takeIf { it in 0..2 }
    }

    private fun stressPatternForPhones(phones: List<String>): List<Int> {
        return phones.mapNotNull(::stressForPhone)
    }

    private fun ipaForPhones(phones: List<String>): String {
        val vowelIndexes = phones.mapIndexedNotNull { index, phone ->
            index.takeIf { basePhone(phone) in vowels }
        }
        val markers = mutableMapOf<Int, String>()

        vowelIndexes.forEachIndexed { vowelIndex, phoneIndex ->
            val stress = stressForPhone(phones[phoneIndex])
            if (stress == null || stress == 0) return@forEachIndexed
            val previousVowel = vowelIndexes.getOrNull(vowelIndex - 1)
            val onsetIndex = if (previousVowel == null) 0 else previousVowel + 1
            markers[onsetIndex] = if (stress == 1) "ˈ" else "ˌ"
        }

        return phones.mapIndexed { index, phone ->
            (markers[index] ?: "") + ipaForPhone(phone)
        }.joinToString("")
    }

    private fun ipaForPhone(phone: String): String {
        val base = basePhone(phone)
        val stress = stressForPhone(phone)
        if (base == "AH" && stress == 0) return "ə"
        if (base == "ER" && stress == 0) return "ɚ"
        return ipaByPhone[base] ?: base.lowercase()
    }

    private fun fallbackStressPattern(word: String): List<Int> {
        val count = fallbackSyllableCount(word)
        if (count == 0) return emptyList()
        return List(count) { index -> if (index == 0) 1 else 0 }
    }

    private fun fallbackSyllableCount(word: String): Int {
        val w = normalizeWord(word)
        if (w.isEmpty()) return 0
        if (w.length <= 2) return 1

        var count = 0
        var prevVowel = false
        val vowelLetters = "aeiouy"

        for (ch in w) {
            val isVowel = ch in vowelLetters
            if (isVowel && !prevVowel) count++
            prevVowel = isVowel
        }

        if (w.endsWith("e") && !w.endsWith("le") && count > 1) count--
        // Vowel+"les" is a silent e ("miles"); consonant+"les" is a syllabic le
        // ("tables") and must keep its count. "les" words are excluded from the
        // generic "es" rule so they are never decremented twice.
        val endsInLes = w.endsWith("les")
        if (endsInLes && w.length >= 4 && w[w.length - 4] in vowelLetters && count > 1) count--
        if (!endsInLes && w.endsWith("es") && !w.endsWith("ses") && !w.endsWith("zes") && count > 1) count--
        if (w.endsWith("ed") && !w.endsWith("ted") && !w.endsWith("ded") && count > 1) count--

        return maxOf(count, 1)
    }

    private fun fallbackRhymeKeys(word: String, maxDepth: Int): List<String> {
        var phonetic = normalizeWord(word)
        if (phonetic.length < 2 || phonetic in stopwords) return emptyList()

        substitutions.forEach { (from, to) ->
            phonetic = phonetic.replace(from, to)
        }
        if (phonetic.length > 2 && phonetic.endsWith("e") && !phonetic.endsWith("le")) {
            phonetic = phonetic.dropLast(1)
        }

        val starts = mutableListOf<Int>()
        var inGroup = false
        phonetic.forEachIndexed { index, ch ->
            val isVowel = ch in "aeiou" || (ch == 'y' && index > 0)
            if (isVowel && !inGroup) starts += index
            inGroup = isVowel
        }

        return starts.takeLast(maxDepth).asReversed().map { start -> phonetic.substring(start) }
    }

    private fun rhymeKeysForPhones(phones: List<String>, maxDepth: Int): List<String> {
        val vowelIndexes = phones.mapIndexedNotNull { index, phone ->
            index.takeIf { basePhone(phone) in vowels }
        }
        if (vowelIndexes.isEmpty()) return emptyList()

        val stressed = vowelIndexes.filter { index -> (stressForPhone(phones[index]) ?: 0) > 0 }
        val anchors = if (stressed.isNotEmpty()) stressed else vowelIndexes
        return anchors
            .takeLast(maxDepth)
            .asReversed()
            .map { index -> phones.drop(index).joinToString(" ") { basePhone(it) } }
    }
}
