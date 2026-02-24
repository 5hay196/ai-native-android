/*
 * Copyright (C) 2026 AI-Native Android Project
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * AINativeService.java
 * System service implementation for the AI-Native LLM inference service.
 *
 * Location in AOSP tree:
 *   frameworks/base/services/core/java/com/android/server/AINativeService.java
 *
 * Registration in SystemServer.java:
 *   import com.android.server.AINativeService;
 *   // In startOtherServices():
 *   traceBeginAndSlog("StartAINativeService");
 *   ServiceManager.addService(Context.AI_NATIVE_SERVICE, new AINativeService(context));
 *   Trace.traceEnd(Trace.TRACE_TAG_SYSTEM_SERVER);
 */
package com.android.server;

import android.app.IAINativeService;
import android.content.Context;
import android.os.Binder;
import android.os.SystemProperties;
import android.util.Log;
import android.util.Slog;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * AINativeService - System service bridging Android framework to the Ollama daemon.
 *
 * Architecture:
 *   Android Apps / Framework
 *       |  (Android Binder IPC)
 *   AINativeService  <-- this class, runs inside system_server
 *       |  (HTTP/localhost or Unix socket)
 *   Ollama daemon (/system/bin/ollama serve)
 *       |  (in-process via llama.cpp)
 *   GGUF model on /data/ollama/models
 *
 * @hide
 */
public class AINativeService extends IAINativeService.Stub {
    private static final String TAG = "AINativeService";

    /** Ollama API base URL - daemon listens on loopback only */
    private static final String OLLAMA_BASE_URL = "http://127.0.0.1:11434";

    /** Default model to load at startup */
    private static final String DEFAULT_MODEL = "llama3.2:3b";

    /** System property to check/set daemon enabled state */
    private static final String PROP_OLLAMA_ENABLED = "persist.ai_native.ollama.enabled";

    private final Context mContext;
    private final AtomicBoolean mDaemonRunning = new AtomicBoolean(false);
    private volatile String mActiveModel = null;

    /** Background executor for non-blocking daemon health checks */
    private final ExecutorService mExecutor = Executors.newSingleThreadExecutor();

    public AINativeService(Context context) {
        mContext = context;
        Slog.i(TAG, "AINativeService created");
        // Schedule a deferred health check after boot
        mExecutor.submit(this::checkDaemonHealth);
    }

    // -------------------------------------------------------------------------
    // IAINativeService implementation
    // -------------------------------------------------------------------------

    @Override
    public String infer(String prompt, int maxTokens, float temperature) {
        enforceCallingPermission();
        if (prompt == null || prompt.isEmpty()) return null;

        // Clamp parameters to safe ranges
        maxTokens = Math.min(Math.max(maxTokens, 1), 2048);
        temperature = Math.min(Math.max(temperature, 0.0f), 2.0f);

        try {
            JSONObject requestBody = new JSONObject();
            requestBody.put("model", mActiveModel != null ? mActiveModel : DEFAULT_MODEL);
            requestBody.put("prompt", prompt);
            requestBody.put("stream", false);

            JSONObject options = new JSONObject();
            options.put("num_predict", maxTokens);
            options.put("temperature", temperature);
            // Pin inference to efficiency cores via num_thread
            options.put("num_thread", 4);
            requestBody.put("options", options);

            String responseJson = postToOllama("/api/generate", requestBody.toString());
            if (responseJson == null) return null;

            JSONObject response = new JSONObject(responseJson);
            return response.optString("response", null);
        } catch (Exception e) {
            Slog.e(TAG, "infer() failed", e);
            return null;
        }
    }

    @Override
    public boolean loadModel(String modelName) {
        enforceCallingPermission();
        if (modelName == null || modelName.isEmpty()) return false;

        try {
            // Ask Ollama to warm up the model by sending an empty generate request
            JSONObject req = new JSONObject();
            req.put("model", modelName);
            req.put("prompt", "");
            req.put("stream", false);

            String resp = postToOllama("/api/generate", req.toString());
            if (resp != null) {
                mActiveModel = modelName;
                Slog.i(TAG, "Model loaded: " + modelName);
                return true;
            }
        } catch (Exception e) {
            Slog.e(TAG, "loadModel() failed for: " + modelName, e);
        }
        return false;
    }

    @Override
    public void unloadModel() {
        enforceCallingPermission();
        try {
            if (mActiveModel != null) {
                // Send keep_alive=0 to force model eviction
                JSONObject req = new JSONObject();
                req.put("model", mActiveModel);
                req.put("keep_alive", 0);
                postToOllama("/api/generate", req.toString());
                mActiveModel = null;
                Slog.i(TAG, "Model unloaded");
            }
        } catch (Exception e) {
            Slog.e(TAG, "unloadModel() failed", e);
        }
    }

    @Override
    public String getActiveModel() {
        return mActiveModel;
    }

    @Override
    public String listModels() {
        try {
            return getFromOllama("/api/tags");
        } catch (Exception e) {
            Slog.e(TAG, "listModels() failed", e);
            return "[]";
        }
    }

    @Override
    public boolean isDaemonRunning() {
        return checkDaemonHealth();
    }

    @Override
    public void startDaemon() {
        enforceCallingPermission();
        SystemProperties.set(PROP_OLLAMA_ENABLED, "1");
        Slog.i(TAG, "Ollama daemon start requested");
    }

    @Override
    public void stopDaemon() {
        enforceCallingPermission();
        unloadModel();
        SystemProperties.set(PROP_OLLAMA_ENABLED, "0");
        mDaemonRunning.set(false);
        Slog.i(TAG, "Ollama daemon stop requested");
    }

    @Override
    public String getInferenceStats() {
        try {
            // Query Ollama's running processes endpoint
            String resp = getFromOllama("/api/ps");
            if (resp == null) return "{}";
            return resp;
        } catch (Exception e) {
            return "{}";
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    private boolean checkDaemonHealth() {
        try {
            URL url = new URL(OLLAMA_BASE_URL + "/");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(500);
            conn.setReadTimeout(500);
            conn.setRequestMethod("GET");
            int code = conn.getResponseCode();
            boolean running = (code == 200);
            mDaemonRunning.set(running);
            conn.disconnect();
            return running;
        } catch (IOException e) {
            mDaemonRunning.set(false);
            return false;
        }
    }

    private String postToOllama(String path, String jsonBody) throws IOException {
        URL url = new URL(OLLAMA_BASE_URL + path);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setConnectTimeout(2000);
        // Allow up to 60 seconds for inference
        conn.setReadTimeout(60000);
        conn.setDoOutput(true);

        try (OutputStream os = conn.getOutputStream()) {
            os.write(jsonBody.getBytes(StandardCharsets.UTF_8));
        }

        int code = conn.getResponseCode();
        if (code != 200) {
            Slog.w(TAG, "Ollama POST " + path + " returned HTTP " + code);
            return null;
        }

        try (BufferedReader br = new BufferedReader(
                new InputStreamReader(conn.getInputStream(), StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) sb.append(line);
            return sb.toString();
        } finally {
            conn.disconnect();
        }
    }

    private String getFromOllama(String path) throws IOException {
        URL url = new URL(OLLAMA_BASE_URL + path);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(2000);
        conn.setReadTimeout(5000);

        int code = conn.getResponseCode();
        if (code != 200) return null;

        try (BufferedReader br = new BufferedReader(
                new InputStreamReader(conn.getInputStream(), StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) sb.append(line);
            return sb.toString();
        } finally {
            conn.disconnect();
        }
    }

    /**
     * Enforce that callers hold the AI_NATIVE_INFERENCE permission.
     * Only privileged system apps and the framework itself are granted this.
     */
    private void enforceCallingPermission() {
        mContext.enforceCallingOrSelfPermission(
                "android.permission.AI_NATIVE_INFERENCE",
                "Requires AI_NATIVE_INFERENCE permission");
    }
}
