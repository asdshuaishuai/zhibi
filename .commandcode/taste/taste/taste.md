# Taste
- Communicates in Chinese and expects Chinese replies. Confidence: 0.6
- Asks for review in numbered, explicit task lists (e.g. "1. 功能审查 2. 交互审查"); mirror that structure in the response. Confidence: 0.5
- Delegates work with extremely terse instructions (e.g. a bare "修复", or a one-word "继续" to resume — often repeated across sessions with no added scope) and expects the agent to derive the priority order, plan the batches, and carry the whole job through end-to-end (including build + self-check verification) without asking for step-by-step confirmation. Confidence: 0.65
- Wants exhaustive, whole-scope audits ("全量") rather than sampling — every file/entry point checked, not a representative subset. Confidence: 0.6
- Distrusts documentation/self-check claims; expects each claimed capability to be verified against the actual code with file:line evidence. Confidence: 0.6
- Treats interaction/UX soundness as a first-class review dimension alongside feature completeness: dead-end flows, inconsistent state, missing feedback, missing confirmations for destructive actions, missing disabled preconditions. Confidence: 0.55
