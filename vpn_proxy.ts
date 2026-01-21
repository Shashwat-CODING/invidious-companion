
import { crypto } from "jsr:@std/crypto";

// --- Configuration ---
const API_BASE = "https://antpeak.com";
const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const APP_VERSION = "3.7.8";

// --- Types ---
interface DeviceInfo {
    udid: string;
    appVersion: string;
    platform: string;
    platformVersion: string;
    timeZone: string;
    deviceName: string;
}

interface Tokens {
    accessToken: string;
    refreshToken: string;
}

interface Location {
    id: string;
    region: string; // The code used for requesting servers
    name: string;
    countryCode: string;
    type: number; // 0 for public/free usually
    proxyType: number; // 0 for free
}

interface Server {
    addresses: string[];
    protocol: string;
    port: number;
    rpz_port?: number;
}

// --- Helpers ---

// Simple UUID v4 generator
function uuidv4(): string {
    return crypto.randomUUID();
}

async function fetchJson(
    endpoint: string,
    method: string,
    body?: any,
    token?: string
): Promise<any> {
    const url = `${API_BASE}${endpoint}`;
    const headers: Record<string, string> = {
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json",
        "Accept": "application/json",
    };

    if (token) {
        headers["Authorization"] = `Bearer ${token}`;
    }

    // console.log(`[DEBUG] ${method} ${url}`);
    try {
        const response = await fetch(url, {
            method,
            headers,
            body: body ? JSON.stringify(body) : undefined,
        });

        if (!response.ok) {
            const text = await response.text();
            throw new Error(`API Error ${response.status}: ${text}`);
        }

        const data = await response.json();
        return data;
    } catch (error) {
        console.error(`Fetch failed for ${url}:`, error);
        throw error;
    }
}

// --- Main Flow ---

async function main() {
    console.log("🚀 Starting VPN Proxy Fetcher...");

    // 1. Generate Device Info
    const udid = uuidv4();
    const deviceInfo: DeviceInfo = {
        udid: udid,
        appVersion: APP_VERSION,
        platform: "chrome",
        platformVersion: USER_AGENT,
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
        deviceName: "Chrome 120.0.0.0",
    };

    // console.log("Device Info:", deviceInfo);

    // 2. Launch / Register (Get Token)
    console.log("Step 1: Registering device (Anonymous Launch)...");
    const launchResponse = await fetchJson("/api/launch/", "POST", deviceInfo); // api/launch/ is usually without auth

    if (!launchResponse.success || !launchResponse.data?.accessToken) {
        console.error("Failed to launch/register:", launchResponse);
        Deno.exit(1);
    }

    const token = launchResponse.data.accessToken;
    console.log("✅ Got Access Token");

    // 3. Get Locations
    console.log("Step 2: Fetching available locations...");
    const locationsResponse = await fetchJson("/api/location/list/", "POST", undefined, token);

    if (!locationsResponse.success || !locationsResponse.data?.locations) {
        console.error("Failed to fetch locations:", locationsResponse);
        Deno.exit(1);
    }

    const locations: Location[] = locationsResponse.data.locations;
    const countries = locationsResponse.data.countries; // For nice printing

    // Filter for free locations (proxyType === 0 and type === 0 usually)
    const freeLocations = locations.filter(l => l.proxyType === 0);

    if (freeLocations.length === 0) {
        console.error("No free locations found.");
        Deno.exit(1);
    }

    // Pick a random location or "optimal" if possible. 
    // Let's pick a random one to distribute load or just the first one.
    const selectedLocation = freeLocations[Math.floor(Math.random() * freeLocations.length)];
    const countryName = countries.find((c: any) => c.code === selectedLocation.countryCode)?.name || selectedLocation.region;

    console.log(`✅ Selected Location: ${countryName} (${selectedLocation.region})`);

    // 4. Get Server List for Location
    // We will try to find an unauthenticated proxy by iterating locations and protocols
    const protocols = ["https", "http"];
    const maxRetries = 10; // Try up to 10 random locations/combinations
    let targetServer: any = null;
    let foundProtocol = "";

    console.log(`Step 3: Searching for unauthenticated proxy (scanning up to ${maxRetries} attempts)...`);

    // Shuffle free locations to try random ones
    const shuffledLocations = freeLocations.sort(() => 0.5 - Math.random());

    for (let i = 0; i < Math.min(shuffledLocations.length, maxRetries); i++) {
        const location = shuffledLocations[i];

        for (const protocol of protocols) {
            const serverPayload = {
                protocol: protocol,
                region: location.region,
                type: location.type
            };

            try {
                // Squelch errors during scan
                const serverResponse = await fetchJson("/api/server/list/", "POST", serverPayload, token).catch(() => ({ success: false }));

                if (serverResponse.success && Array.isArray(serverResponse.data) && serverResponse.data.length > 0) {
                    const servers = serverResponse.data;

                    // Check specifically for unauthenticated server
                    const unauthServer = servers.find((s: any) => !s.username || s.username === "");

                    if (unauthServer) {
                        targetServer = unauthServer;
                        foundProtocol = protocol;
                        console.log(`✅ Found unauthenticated proxy in ${location.region} (${protocol})`);
                        break;
                    } else if (!targetServer) {
                        // Keep the first valid authenticated one as fallback
                        targetServer = servers[0];
                        foundProtocol = protocol;
                    }
                }
            } catch (e) {
                // ignore
            }
        }
        if (targetServer && (!targetServer.username || targetServer.username === "")) {
            break; // Found our gold standard
        }
    }

    if (!targetServer) {
        console.error("Failed to fetch any proxy servers after multiple attempts.");
        Deno.exit(1);
    }

    // Check if we actually found what we wanted
    if (targetServer.username) {
        console.log("⚠️  No unauthenticated proxies found after scanning. Using authenticated proxy.");
    }

    const ip = targetServer.addresses[0];
    const port = targetServer.port;
    const username = targetServer.username || "";
    const password = targetServer.password || "";
    const isUnauth = !username;

    // Construct the proxy URL with embedded credentials if needed
    // Format: protocol://username:password@host:port or protocol://host:port
    let finalProxyUrl = "";
    if (isUnauth) {
        finalProxyUrl = `${foundProtocol}://${ip}:${port}`;
    } else {
        finalProxyUrl = `${foundProtocol}://${username}:${password}@${ip}:${port}`;
    }

    console.log("\nStep 4: Verifying proxy connection...");

    try {
        const client = Deno.createHttpClient({
            proxy: {
                url: finalProxyUrl,
            },
        });

        const testUrl = "https://httpbin.org/ip";
        // console.log(`Testing against ${testUrl}...`);

        const response = await fetch(testUrl, {
            client,
        });

        const text = await response.text();
        client.close();

        if (response.ok) {
            console.log("✅ Proxy verification successful!");
            console.log(`\nFinal Proxy URL (Embedded Credentials):`);
            console.log(finalProxyUrl);
        } else {
            console.error("❌ Proxy verification failed.", response.status, text);
            // Optionally we could loop and try another, but for now we report
        }

    } catch (err) {
        console.error("❌ Proxy verification failed (Network Error):", err);
    }
}

if (import.meta.main) {
    try {
        await main();
    } catch (err) {
        console.error("Runtime Error:", err);
        Deno.exit(1);
    }
}
