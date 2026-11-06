const std = @import("std");

pub const environment_names = [_][]const u8{
    "CODEX_ACCESS_TOKEN",  "CODEX_REFRESH_TOKEN",    "OPENAI_AUTH_TOKEN",     "OPENAI_REFRESH_TOKEN",
    "NIB_API_KEY",         "CODEX_API_KEY",          "DEEPSEEK_API_KEY",      "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",   "OPENAI_ACCESS_TOKEN",    "ANTHROPIC_AUTH_TOKEN",  "AZURE_OPENAI_API_KEY",
    "AZURE_OPENAI_KEY",    "GEMINI_API_KEY",         "GOOGLE_API_KEY",        "GROQ_API_KEY",
    "MISTRAL_API_KEY",     "COHERE_API_KEY",         "TOGETHER_API_KEY",      "OPENROUTER_API_KEY",
    "HF_TOKEN",            "HUGGING_FACE_HUB_TOKEN", "GITHUB_TOKEN",          "GH_TOKEN",
    "GITLAB_TOKEN",        "AWS_ACCESS_KEY_ID",      "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "AZURE_CLIENT_SECRET", "XAI_API_KEY",
};

pub fn removeFrom(env: *std.process.Environ.Map) void {
    for (environment_names) |name| _ = env.swapRemove(name);
}
