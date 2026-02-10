import type { AuthConfig } from "convex/server";

export default {
	providers: [
		{
			domain: "https://appleid.apple.com",
			applicationID: "com.splt.money",
		},
		{
			domain: "https://appleid.apple.com",
			applicationID: "com.tabbyapp.app",
		},
	],
} satisfies AuthConfig;
