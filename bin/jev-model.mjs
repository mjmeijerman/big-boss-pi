/**
 * The one place that says which local model jev and local-run talk to.
 *
 * Both bin/jev.mjs (the decision model) and bin/local-run (the local worker) import these,
 * so routing to "local" and actually running locally can never drift apart.
 */
import process from "node:process";

export const MODEL = process.env.JEV_MODEL || "qwen3.8:27b";
export const ENDPOINT = process.env.JEV_ENDPOINT || "http://localhost:11434/api/chat";
export const TIMEOUT = Number(process.env.JEV_TIMEOUT || 180000);
// How long ollama keeps the model loaded after a call. Ollama's default is 5 minutes, so a
// spawn more than 5 minutes after the last one pays the model load again (8s instead of 3s).
// 30m covers a work session: one load per session, not one per spawn.
export const KEEP_ALIVE = process.env.JEV_KEEP_ALIVE || "30m";
