package dev.bluetoothswitch.relay;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Public reports only; credentials and GitHub permissions live on the server. */
final class ProblemReports {
    private final SharedPreferences drafts;
    private final String version;
    ProblemReports(Context context) { drafts=context.getSharedPreferences("problem-report",Context.MODE_PRIVATE);String build="unknown";try{android.content.pm.PackageInfo info=context.getPackageManager().getPackageInfo(context.getPackageName(),0);build=info.versionName+" ("+info.getLongVersionCode()+")";}catch(Exception ignored){}version=build;if(saved("installationId").isEmpty())drafts.edit().putString("installationId",UUID.randomUUID().toString()).commit(); }
    String saved(String key) { return drafts.getString(key,""); }
    void save(String title,String description) { drafts.edit().putString("title",title).putString("description",description).apply(); }
    String payload(String title,String description,boolean details) throws Exception {
        JSONObject context=new JSONObject();
        if(details){context.put("version",version);context.put("os","Android API "+android.os.Build.VERSION.SDK_INT);}
        JSONObject data=new JSONObject().put("installationId",saved("installationId")).put("title",title.trim()).put("description",description.trim()).put("platform","Android").put("context",context);
        String previous=saved("payload");
        if(!previous.isEmpty()) { JSONObject old=new JSONObject(previous);String id=old.getString("id");old.remove("id");if(old.toString().equals(data.toString()))return previous; }
        data.put("id",UUID.randomUUID().toString());String value=data.toString();drafts.edit().putString("payload",value).commit();return value;
    }
    static boolean validURL(String url){return url.matches("https://github\\.com/Json604/pairIt-download/issues/[1-9][0-9]*");}
    void completed(){drafts.edit().remove("payload").remove("title").remove("description").apply();}
    void updateQuota(JSONObject result){if(result.has("remaining"))drafts.edit().putLong("blockedUntil",result.optInt("remaining") == 0 ? System.currentTimeMillis()+result.optLong("retryAfter",0)*1000L : 0).apply();}
    long waitSeconds(){return Math.max(0,(drafts.getLong("blockedUntil",0)-System.currentTimeMillis()+999)/1000);}
    JSONObject quota() throws Exception {return request(new JSONObject().put("installationId",saved("installationId")).toString(),"/quota");}
    static JSONObject send(String payload) throws Exception {return request(payload,"");}
    private static JSONObject request(String payload,String suffix) throws Exception {
        HttpURLConnection connection=(HttpURLConnection)new URL("https://reports.pairit.kartikey.xyz/v1/reports"+suffix).openConnection();
        try {
            connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(15000);connection.setReadTimeout(25000);connection.setRequestMethod("POST");connection.setDoOutput(true);connection.setRequestProperty("Content-Type","application/json");
            byte[] bytes=payload.getBytes(StandardCharsets.UTF_8);connection.setFixedLengthStreamingMode(bytes.length);
            try(java.io.OutputStream stream=connection.getOutputStream()){stream.write(bytes);}
            int status=connection.getResponseCode();java.io.InputStream input=status>=400?connection.getErrorStream():connection.getInputStream();
            if(input==null)throw new java.io.IOException();
            java.io.ByteArrayOutputStream body=new java.io.ByteArrayOutputStream();
            try(java.io.InputStream stream=input){byte[] buffer=new byte[1024];int n;while((n=stream.read(buffer))!=-1){if(body.size()+n>8192)throw new java.io.IOException();body.write(buffer,0,n);}}
            JSONObject result=new JSONObject(body.toString("UTF-8"));
            if((status==200||status==201)&&validURL(result.optString("url")))return result;
            return result;
        } finally {connection.disconnect();}
    }
}
