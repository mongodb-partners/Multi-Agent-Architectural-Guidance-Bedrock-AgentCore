/**
 * Pure, deterministic, dependency-free handoff attribution.
 *
 * Given the user message, the orchestrator's pre-handoff reasoning, the chosen
 * specialist, the orchestrator's `handoffs[]` frontmatter, and a way to look up
 * agent metadata, compute:
 *  - `triggerSpans`: tokenized overlaps between {user message, orchestrator reasoning}
 *    and {agent.description, agent.skills, handoffs[].label, handoffs[].prompt},
 *    with offsets into the *original-cased* source string (so the UI can highlight
 *    matched substrings precisely).
 *  - `alternativesConsidered`: same scoring applied to every *other* entry in the
 *    orchestrator's `handoffs[]`, sorted descending by score.
 *  - `chosenScore` + `confidence` in [0, 1] — or `null` when nothing matched.
 *
 * The module is intentionally I/O-free so it's trivial to unit-test in isolation.
 */

export type TriggerSpan = {
  phrase: string;
  source: "userMessage" | "orchestratorReasoning";
  offset: [number, number];
  matchedAgainst: "description" | "handoff.label" | "handoff.prompt" | "skill";
  matchedAgainstValue: string;
};

export type AlternativeScore = {
  agentId: string;
  label?: string;
  score: number;
  matchedPhrases: string[];
};

export type AttributionResult = {
  triggerSpans: TriggerSpan[];
  alternativesConsidered: AlternativeScore[];
  chosenScore: number;
  /** Smoothed ratio of chosen / total. `null` when nothing scored. */
  confidence: number | null;
};

export type HandoffsEntry = { label: string; agent: string; prompt?: string };
export type AgentMeta = { description?: string; skills?: string[] };

export type AttributeHandoffInput = {
  userMessage: string;
  orchestratorReasoning: string;
  chosenAgentId: string;
  orchestratorHandoffs: HandoffsEntry[];
  agentMeta: (id: string) => AgentMeta | undefined;
};

// ---------------------------------------------------------------------------
// Tokenization
// ---------------------------------------------------------------------------

const STOPWORDS = new Set([
  "the", "a", "an", "and", "or", "of", "to", "is", "are", "for", "with",
  "my", "i", "you", "this", "that", "we", "he", "she", "it", "in", "on",
  "at", "by", "be", "as", "if", "do", "did", "had", "has", "have", "will",
  "would", "should", "could", "can", "may", "might", "shall", "yes", "no",
]);

const TOKEN_SPLIT = /[^a-z0-9_-]+/i;

/** Lowercase + split + drop stopwords / very short tokens. */
function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(TOKEN_SPLIT)
    .filter((t) => t.length > 2 && !STOPWORDS.has(t));
}

function bigramsOf(tokens: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i + 1 < tokens.length; i++) {
    out.push(`${tokens[i]} ${tokens[i + 1]}`);
  }
  return out;
}

/**
 * Find the original-cased substring offsets of `needle` (case-insensitive) in
 * `haystack`. Returns the first hit only (multiple hits are de-duplicated at the
 * span level).
 */
function findOffset(haystack: string, needle: string): [number, number] | undefined {
  if (!needle) return undefined;
  const idx = haystack.toLowerCase().indexOf(needle.toLowerCase());
  if (idx === -1) return undefined;
  return [idx, idx + needle.length];
}

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

type CandidateBundle = {
  agentId: string;
  label?: string;
  /** Strings to score the source text against. */
  targets: Array<{ value: string; against: TriggerSpan["matchedAgainst"] }>;
};

function buildCandidate(
  entry: HandoffsEntry,
  meta: AgentMeta | undefined,
): CandidateBundle {
  const targets: CandidateBundle["targets"] = [];
  if (entry.label) targets.push({ value: entry.label, against: "handoff.label" });
  if (entry.prompt) targets.push({ value: entry.prompt, against: "handoff.prompt" });
  if (meta?.description) targets.push({ value: meta.description, against: "description" });
  for (const skill of meta?.skills ?? []) {
    if (skill) targets.push({ value: skill, against: "skill" });
  }
  return { agentId: entry.agent, label: entry.label, targets };
}

function scoreSourceAgainstCandidate(
  sourceTokens: Set<string>,
  sourceBigrams: Set<string>,
  candidate: CandidateBundle,
): { score: number; matchedPhrases: string[]; spans: Array<Omit<TriggerSpan, "source" | "offset">> } {
  let score = 0;
  const matchedPhrases = new Set<string>();
  const spans: Array<Omit<TriggerSpan, "source" | "offset">> = [];

  for (const target of candidate.targets) {
    const tTokens = new Set(tokenize(target.value));
    const tBigrams = new Set(bigramsOf(Array.from(tTokens)));
    for (const tok of tTokens) {
      if (sourceTokens.has(tok)) {
        score += Math.log(1 + tok.length);
        matchedPhrases.add(tok);
        spans.push({
          phrase: tok,
          matchedAgainst: target.against,
          matchedAgainstValue: target.value,
        });
      }
    }
    for (const bg of tBigrams) {
      if (sourceBigrams.has(bg)) {
        score += 1.5;
        matchedPhrases.add(bg);
        spans.push({
          phrase: bg,
          matchedAgainst: target.against,
          matchedAgainstValue: target.value,
        });
      }
    }
  }
  return { score, matchedPhrases: Array.from(matchedPhrases), spans };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export function attributeHandoff(input: AttributeHandoffInput): AttributionResult {
  const { userMessage, orchestratorReasoning, chosenAgentId, orchestratorHandoffs, agentMeta } = input;

  // Tokenize both sources once.
  const userTokens = tokenize(userMessage);
  const userTokenSet = new Set(userTokens);
  const userBigramSet = new Set(bigramsOf(userTokens));
  const reasoningTokens = tokenize(orchestratorReasoning);
  const reasoningTokenSet = new Set(reasoningTokens);
  const reasoningBigramSet = new Set(bigramsOf(reasoningTokens));

  let chosen: AlternativeScore | undefined;
  const alternatives: AlternativeScore[] = [];
  const triggerSpans: TriggerSpan[] = [];

  for (const entry of orchestratorHandoffs) {
    const candidate = buildCandidate(entry, agentMeta(entry.agent));

    const userMatch = scoreSourceAgainstCandidate(userTokenSet, userBigramSet, candidate);
    const reasonMatch = scoreSourceAgainstCandidate(
      reasoningTokenSet,
      reasoningBigramSet,
      candidate,
    );

    const totalScore = userMatch.score + reasonMatch.score;
    const matchedPhrases = Array.from(
      new Set([...userMatch.matchedPhrases, ...reasonMatch.matchedPhrases]),
    );
    const item: AlternativeScore = {
      agentId: entry.agent,
      label: entry.label,
      score: Number(totalScore.toFixed(3)),
      matchedPhrases,
    };

    if (entry.agent === chosenAgentId) {
      chosen = item;
      // Compute trigger spans against the original cased source.
      const dedupe = new Set<string>();
      const pushSpan = (
        span: Omit<TriggerSpan, "source" | "offset">,
        source: TriggerSpan["source"],
        text: string,
      ) => {
        const key = `${span.phrase}::${source}::${span.matchedAgainst}`;
        if (dedupe.has(key)) return;
        const offset = findOffset(text, span.phrase);
        if (!offset) return;
        dedupe.add(key);
        triggerSpans.push({ ...span, source, offset });
      };
      for (const s of userMatch.spans) pushSpan(s, "userMessage", userMessage);
      for (const s of reasonMatch.spans) pushSpan(s, "orchestratorReasoning", orchestratorReasoning);
    } else {
      alternatives.push(item);
    }
  }

  alternatives.sort((a, b) => b.score - a.score);

  const chosenScore = chosen?.score ?? 0;
  const sumAlt = alternatives.reduce((acc, a) => acc + a.score, 0);
  const totalSignal = chosenScore + sumAlt;
  const epsilon = 0.5;
  const confidence =
    totalSignal === 0 ? null : Number((chosenScore / (chosenScore + sumAlt + epsilon)).toFixed(3));

  return {
    triggerSpans,
    alternativesConsidered: alternatives,
    chosenScore,
    confidence,
  };
}
