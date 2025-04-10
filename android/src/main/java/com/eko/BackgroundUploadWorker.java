package com.eko;

import android.content.Context;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.work.Data;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;

import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

public class BackgroundUploadWorker extends Worker {

    public BackgroundUploadWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        String id = getInputData().getString("id");
        String urlString = getInputData().getString("url");
        String source = getInputData().getString("source");
        String method = getInputData().getString("method");

        File file = new File(source);
        if (!file.exists()) {
            sendEvent("uploadFailed", id, "File not found");
            return Result.failure();
        }

        try {
            URL url = new URL(urlString);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod(method != null ? method : "POST");
            conn.setDoOutput(true);

            sendEvent("uploadBegin", id, null);

            byte[] buffer = new byte[512 * 1024];
            int bytesRead;
            long totalBytesSent = 0;
            long fileLength = file.length();

            try (
                FileInputStream fis = new FileInputStream(file);
                OutputStream os = new BufferedOutputStream(conn.getOutputStream())
            ) {
                while ((bytesRead = fis.read(buffer)) != -1) {
                    os.write(buffer, 0, bytesRead);
                    totalBytesSent += bytesRead;
                    sendProgressEvent(id, totalBytesSent, fileLength);
                }
            }

            int status = conn.getResponseCode();
            if (status >= 200 && status < 300) {
                sendDoneEvent(id, totalBytesSent, fileLength);
                return Result.success();
            } else {
                sendEvent("uploadFailed", id, method + " Server responded with status: " + status);
                return Result.failure();
            }

        } catch (Exception e) {
            sendEvent("uploadFailed", id, e.getMessage());
            return Result.retry();
        }
    }

    private void sendEvent(String eventName, String id, String errorMessage) {
        WritableMap params = Arguments.createMap();
        params.putString("id", id);
        if (errorMessage != null) {
            params.putString("error", errorMessage);
        }

        RNBackgroundDownloaderModule.sendStaticEvent(eventName, params);
    }

    private void sendProgressEvent(String id, long sent, long total) {
        WritableMap map = Arguments.createMap();
        map.putString("id", id);
        map.putDouble("bytes", sent);
        map.putDouble("bytesTotal", total);
        WritableArray reportsArray = Arguments.createArray();
        reportsArray.pushMap(map.copy());

        RNBackgroundDownloaderModule.sendStaticEvent("uploadProgress", reportsArray);
    }

    private void sendDoneEvent(String id, long sent, long total) {
        WritableMap map = Arguments.createMap();
        map.putString("id", id);
        map.putDouble("bytes", sent);
        map.putDouble("bytesTotal", total);
        RNBackgroundDownloaderModule.sendStaticEvent("uploadComplete", map);
    }
}