package com.eko;

import java.io.Serializable;

public class RNBGDTaskConfig implements Serializable {
    public String id;
    public Integer type;
    public String url;
    public String destination;
    public String source;
    public String method;
    public String metadata = "{}";
    public String notificationTitle;
    public boolean reportedBegin;

    public RNBGDTaskConfig(String id, Integer type, String url, String destination, String source, String method, String metadata, String notificationTitle) {
        this.id = id;
        this.type = type;
        this.url = url;
        this.destination = destination;
        this.source = source;
        this.method = method;
        this.metadata = metadata;
        this.notificationTitle = notificationTitle;
        this.reportedBegin = false;
    }
}
