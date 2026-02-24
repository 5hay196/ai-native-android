/*
 * Copyright (C) 2026 AI-Native Android Project
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * IAINativeService.aidl
 * AIDL interface for the AI-Native system service.
 *
 * This interface is exposed via Android Binder so that:
 *  - Apps can request LLM inference via Context.getSystemService(AI_NATIVE_SERVICE)
 *  - Framework code (BatteryPredictionService, NotificationIntelligence) can call
 *    inference synchronously within the system_server process
 *
 * Location in AOSP tree:
 *   frameworks/base/core/java/android/app/IAINativeService.aidl
 * Add to frameworks/base/Android.bp:
 *   "core/java/android/app/IAINativeService.aidl",
 */
package android.app;

/**
 * System-level interface to the AI-Native inference service.
 * @hide
 */
interface IAINativeService {

    /**
     * Perform a synchronous text inference using the currently loaded model.
     *
     * @param prompt      The user or system prompt to send to the model.
     * @param maxTokens   Maximum number of tokens to generate (1-2048).
     * @param temperature Sampling temperature (0.0 = greedy, 1.0 = creative).
     * @return The model's text response, or null on error.
     */
    @nullable String infer(in String prompt, int maxTokens, float temperature);

    /**
     * Load a specific GGUF model into Ollama.
     * Models are stored in /data/ollama/models.
     *
     * @param modelName  Ollama model name, e.g. "llama3.2:3b" or "qwen2.5-coder:7b"
     * @return true if the model was loaded successfully.
     */
    boolean loadModel(in String modelName);

    /**
     * Unload the current model to free memory.
     * Call this when AI features are not needed for an extended period.
     */
    void unloadModel();

    /**
     * Get the name of the currently loaded model.
     * @return model name string, or null if no model is loaded.
     */
    @nullable String getActiveModel();

    /**
     * List all locally available models (downloaded to /data/ollama/models).
     * @return JSON array string of model descriptors.
     */
    String listModels();

    /**
     * Check whether the Ollama daemon is currently running.
     * Apps should check this before calling infer() to avoid blocking.
     * @return true if the daemon is up and accepting requests.
     */
    boolean isDaemonRunning();

    /**
     * Request the system to start the Ollama daemon.
     * Requires android.permission.AI_NATIVE_INFERENCE.
     * The daemon is started asynchronously; poll isDaemonRunning().
     */
    void startDaemon();

    /**
     * Request the system to stop the Ollama daemon.
     * This unloads all models and frees GPU/CPU memory.
     * Requires android.permission.AI_NATIVE_INFERENCE.
     */
    void stopDaemon();

    /**
     * Get current inference statistics.
     * @return JSON object: {"tokens_per_second": float, "context_used": int,
     *                       "model": string, "memory_mb": int}
     */
    String getInferenceStats();
}
