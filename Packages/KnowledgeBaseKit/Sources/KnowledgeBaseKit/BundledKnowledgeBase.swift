import Foundation
import ObservationCore

/// The knowledge base compiled into the app.
///
/// The bundled dataset is trusted because it ships inside the app's own code
/// signature; anything downloaded later must pass `KnowledgeBaseVerifier`
/// (KB-002). Fire Privacy always has a usable dataset offline (§18.4), and a
/// failed or refused update leaves this one in place.
///
/// Classification wording is deliberately factual — what an endpoint is
/// documented to do, with a citation — because a category shown next to a
/// company name is a claim about that company (§25).
public enum BundledKnowledgeBase {
    public static let datasetVersion = "kb-2026.08.31"

    /// Decoded once. A decode failure yields an empty dataset rather than a
    /// crash: the app still works, and the Trust Center reports the problem.
    public static let payload: KnowledgeBasePayload = {
        do {
            return try decode()
        } catch {
            return KnowledgeBasePayload(datasetVersion: datasetVersion, sources: [], classifications: [])
        }
    }()

    public static let snapshot = KnowledgeBaseSnapshot(
        manifest: nil,
        payload: payload,
        origin: .bundled,
        installedAt: Date(timeIntervalSince1970: 1_788_134_400) // 2026-08-31
    )

    public static func decode() throws -> KnowledgeBasePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KnowledgeBasePayload.self, from: Data(json.utf8))
    }

    public static let json: String = #"""
{
  "datasetVersion": "kb-2026.08.31",
  "sources": [
    {
      "id": "src.google.firebase",
      "title": "Firebase documentation",
      "url": "https://firebase.google.com/docs",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.google.ads",
      "title": "Google Mobile Ads SDK documentation",
      "url": "https://developers.google.com/admob/ios/quick-start",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.meta.ios",
      "title": "Meta SDK for iOS documentation",
      "url": "https://developers.facebook.com/docs/ios",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.branch",
      "title": "Branch developer hub",
      "url": "https://help.branch.io/developers-hub",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.amplitude",
      "title": "Amplitude documentation",
      "url": "https://amplitude.com/docs",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.mixpanel",
      "title": "Mixpanel documentation",
      "url": "https://docs.mixpanel.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.segment",
      "title": "Segment documentation",
      "url": "https://segment.com/docs",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.adjust",
      "title": "Adjust help center",
      "url": "https://help.adjust.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.appsflyer",
      "title": "AppsFlyer developer hub",
      "url": "https://dev.appsflyer.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.unity.ads",
      "title": "Unity Ads documentation",
      "url": "https://docs.unity.com/ads",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.applovin",
      "title": "AppLovin developer documentation",
      "url": "https://developers.applovin.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.ironsource",
      "title": "ironSource mobile documentation",
      "url": "https://developers.is.com/ironsource-mobile/ios/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.inmobi",
      "title": "InMobi SDK documentation",
      "url": "https://www.inmobi.com/sdk",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.criteo",
      "title": "Criteo developer documentation",
      "url": "https://developers.criteo.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.taboola",
      "title": "Taboola developer documentation",
      "url": "https://developers.taboola.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.outbrain",
      "title": "Outbrain developer documentation",
      "url": "https://www.outbrain.com/developers/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.comscore",
      "title": "Comscore ScorecardResearch",
      "url": "https://www.scorecardresearch.com/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.chartbeat",
      "title": "Chartbeat documentation",
      "url": "https://docs.chartbeat.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.newrelic",
      "title": "New Relic mobile monitoring documentation",
      "url": "https://docs.newrelic.com/docs/mobile-monitoring/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.sentry",
      "title": "Sentry Apple platform documentation",
      "url": "https://docs.sentry.io/platforms/apple/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.bugsnag",
      "title": "Bugsnag iOS documentation",
      "url": "https://docs.bugsnag.com/platforms/ios/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.onesignal",
      "title": "OneSignal documentation",
      "url": "https://documentation.onesignal.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.braze",
      "title": "Braze documentation",
      "url": "https://www.braze.com/docs",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.iterable",
      "title": "Iterable support documentation",
      "url": "https://support.iterable.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.clevertap",
      "title": "CleverTap developer documentation",
      "url": "https://developer.clevertap.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.kochava",
      "title": "Kochava support documentation",
      "url": "https://support.kochava.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.singular",
      "title": "Singular support documentation",
      "url": "https://support.singular.net",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.tenjin",
      "title": "Tenjin documentation",
      "url": "https://docs.tenjin.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.apple.push",
      "title": "Apple push notification documentation",
      "url": "https://developer.apple.com/documentation/usernotifications",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.aws.cloudfront",
      "title": "Amazon CloudFront documentation",
      "url": "https://docs.aws.amazon.com/AmazonCloudFront/",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.akamai",
      "title": "Akamai technical documentation",
      "url": "https://techdocs.akamai.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.fastly",
      "title": "Fastly developer documentation",
      "url": "https://developer.fastly.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.cloudflare",
      "title": "Cloudflare developer documentation",
      "url": "https://developers.cloudflare.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.stripe",
      "title": "Stripe documentation",
      "url": "https://docs.stripe.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.paypal",
      "title": "PayPal developer documentation",
      "url": "https://developer.paypal.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.auth0",
      "title": "Auth0 documentation",
      "url": "https://auth0.com/docs",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.okta",
      "title": "Okta developer documentation",
      "url": "https://developer.okta.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.sift",
      "title": "Sift developer documentation",
      "url": "https://sift.com/developers",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.arkose",
      "title": "Arkose Labs developer documentation",
      "url": "https://developer.arkoselabs.com",
      "type": "vendorDocumentation",
      "retrievedAt": "2026-08-31T00:00:00Z"
    },
    {
      "id": "src.demo",
      "title": "Fire Privacy synthetic demonstration dataset",
      "url": null,
      "type": "internalReview",
      "retrievedAt": "2026-08-31T00:00:00Z"
    }
  ],
  "classifications": [
    {
      "id": "kb.app-measurement.com",
      "pattern": "app-measurement.com",
      "patternKind": "domainSuffix",
      "organization": "Google",
      "sdkFamily": "Google Analytics for Firebase",
      "categories": [
        "analytics",
        "attribution"
      ],
      "purposes": [
        "Mobile app measurement and event reporting"
      ],
      "confidence": 0.92,
      "sourceIDs": [
        "src.google.firebase"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.google-analytics.com",
      "pattern": "google-analytics.com",
      "patternKind": "domainSuffix",
      "organization": "Google",
      "sdkFamily": "Google Analytics",
      "categories": [
        "analytics"
      ],
      "purposes": [
        "Web and app analytics"
      ],
      "confidence": 0.92,
      "sourceIDs": [
        "src.google.firebase"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.firebaseinstallations.googleapis.com",
      "pattern": "firebaseinstallations.googleapis.com",
      "patternKind": "exactHost",
      "organization": "Google",
      "sdkFamily": "Firebase",
      "categories": [
        "telemetry"
      ],
      "purposes": [
        "Firebase installation identifiers"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.google.firebase"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Required by many Firebase features that are not analytics.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.crashlytics.com",
      "pattern": "crashlytics.com",
      "patternKind": "domainSuffix",
      "organization": "Google",
      "sdkFamily": "Firebase Crashlytics",
      "categories": [
        "crashReporting"
      ],
      "purposes": [
        "Crash and stability reporting"
      ],
      "confidence": 0.92,
      "sourceIDs": [
        "src.google.firebase"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.doubleclick.net",
      "pattern": "doubleclick.net",
      "patternKind": "domainSuffix",
      "organization": "Google",
      "sdkFamily": "Google Ads",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving and measurement"
      ],
      "confidence": 0.93,
      "sourceIDs": [
        "src.google.ads"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.googlesyndication.com",
      "pattern": "googlesyndication.com",
      "patternKind": "domainSuffix",
      "organization": "Google",
      "sdkFamily": "Google AdSense / AdMob",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving"
      ],
      "confidence": 0.93,
      "sourceIDs": [
        "src.google.ads"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.googleadservices.com",
      "pattern": "googleadservices.com",
      "patternKind": "domainSuffix",
      "organization": "Google",
      "sdkFamily": "Google Ads",
      "categories": [
        "advertising",
        "attribution"
      ],
      "purposes": [
        "Ad click measurement"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.google.ads"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.graph.facebook.com",
      "pattern": "graph.facebook.com",
      "patternKind": "exactHost",
      "organization": "Meta",
      "sdkFamily": "Facebook SDK for iOS",
      "categories": [
        "social",
        "analytics",
        "attribution"
      ],
      "purposes": [
        "App events, login and measurement for apps using the Meta SDK"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.meta.ios"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Also used for ordinary Facebook login and sharing features.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.an.facebook.com",
      "pattern": "an.facebook.com",
      "patternKind": "exactHost",
      "organization": "Meta",
      "sdkFamily": "Meta Audience Network",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.meta.ios"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.branch.io",
      "pattern": "branch.io",
      "patternKind": "domainSuffix",
      "organization": "Branch Metrics",
      "sdkFamily": "Branch",
      "categories": [
        "attribution"
      ],
      "purposes": [
        "Deep linking and install attribution"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.branch"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.amplitude.com",
      "pattern": "amplitude.com",
      "patternKind": "domainSuffix",
      "organization": "Amplitude",
      "sdkFamily": "Amplitude",
      "categories": [
        "analytics"
      ],
      "purposes": [
        "Product analytics"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.amplitude"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.mixpanel.com",
      "pattern": "mixpanel.com",
      "patternKind": "domainSuffix",
      "organization": "Mixpanel",
      "sdkFamily": "Mixpanel",
      "categories": [
        "analytics"
      ],
      "purposes": [
        "Product analytics"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.mixpanel"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.segment.io",
      "pattern": "segment.io",
      "patternKind": "domainSuffix",
      "organization": "Twilio Segment",
      "sdkFamily": "Segment",
      "categories": [
        "analytics",
        "personalization"
      ],
      "purposes": [
        "Customer data collection and routing"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.segment"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.segment.com",
      "pattern": "segment.com",
      "patternKind": "domainSuffix",
      "organization": "Twilio Segment",
      "sdkFamily": "Segment",
      "categories": [
        "analytics",
        "personalization"
      ],
      "purposes": [
        "Customer data collection and routing"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.segment"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.adjust.com",
      "pattern": "adjust.com",
      "patternKind": "domainSuffix",
      "organization": "Adjust",
      "sdkFamily": "Adjust",
      "categories": [
        "attribution",
        "analytics"
      ],
      "purposes": [
        "Install attribution and marketing measurement"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.adjust"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.appsflyer.com",
      "pattern": "appsflyer.com",
      "patternKind": "domainSuffix",
      "organization": "AppsFlyer",
      "sdkFamily": "AppsFlyer",
      "categories": [
        "attribution",
        "analytics"
      ],
      "purposes": [
        "Install attribution and marketing measurement"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.appsflyer"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.unityads.unity3d.com",
      "pattern": "unityads.unity3d.com",
      "patternKind": "domainSuffix",
      "organization": "Unity",
      "sdkFamily": "Unity Ads",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving in games"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.unity.ads"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.applovin.com",
      "pattern": "applovin.com",
      "patternKind": "domainSuffix",
      "organization": "AppLovin",
      "sdkFamily": "AppLovin MAX",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving and mediation"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.applovin"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.supersonicads.com",
      "pattern": "supersonicads.com",
      "patternKind": "domainSuffix",
      "organization": "Unity (ironSource)",
      "sdkFamily": "ironSource",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving and mediation"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.ironsource"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.inmobi.com",
      "pattern": "inmobi.com",
      "patternKind": "domainSuffix",
      "organization": "InMobi",
      "sdkFamily": "InMobi",
      "categories": [
        "advertising"
      ],
      "purposes": [
        "Ad serving"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.inmobi"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.criteo.com",
      "pattern": "criteo.com",
      "patternKind": "domainSuffix",
      "organization": "Criteo",
      "sdkFamily": "Criteo",
      "categories": [
        "advertising",
        "personalization"
      ],
      "purposes": [
        "Retargeting and ad serving"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.criteo"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.criteo.net",
      "pattern": "criteo.net",
      "patternKind": "domainSuffix",
      "organization": "Criteo",
      "sdkFamily": "Criteo",
      "categories": [
        "advertising",
        "personalization"
      ],
      "purposes": [
        "Retargeting and ad serving"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.criteo"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.taboola.com",
      "pattern": "taboola.com",
      "patternKind": "domainSuffix",
      "organization": "Taboola",
      "sdkFamily": "Taboola",
      "categories": [
        "advertising",
        "content",
        "personalization"
      ],
      "purposes": [
        "Content recommendation and ad serving"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.taboola"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.outbrain.com",
      "pattern": "outbrain.com",
      "patternKind": "domainSuffix",
      "organization": "Outbrain",
      "sdkFamily": "Outbrain",
      "categories": [
        "advertising",
        "content",
        "personalization"
      ],
      "purposes": [
        "Content recommendation and ad serving"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.outbrain"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.scorecardresearch.com",
      "pattern": "scorecardresearch.com",
      "patternKind": "domainSuffix",
      "organization": "Comscore",
      "sdkFamily": "ScorecardResearch",
      "categories": [
        "analytics"
      ],
      "purposes": [
        "Audience measurement"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.comscore"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.chartbeat.net",
      "pattern": "chartbeat.net",
      "patternKind": "domainSuffix",
      "organization": "Chartbeat",
      "sdkFamily": "Chartbeat",
      "categories": [
        "analytics"
      ],
      "purposes": [
        "Content engagement analytics"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.chartbeat"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.kochava.com",
      "pattern": "kochava.com",
      "patternKind": "domainSuffix",
      "organization": "Kochava",
      "sdkFamily": "Kochava",
      "categories": [
        "attribution",
        "analytics"
      ],
      "purposes": [
        "Install attribution and marketing measurement"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.kochava"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.singular.net",
      "pattern": "singular.net",
      "patternKind": "domainSuffix",
      "organization": "Singular",
      "sdkFamily": "Singular",
      "categories": [
        "attribution",
        "analytics"
      ],
      "purposes": [
        "Install attribution and marketing measurement"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.singular"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.tenjin.io",
      "pattern": "tenjin.io",
      "patternKind": "domainSuffix",
      "organization": "Tenjin",
      "sdkFamily": "Tenjin",
      "categories": [
        "attribution",
        "analytics"
      ],
      "purposes": [
        "Install attribution"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.tenjin"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.nr-data.net",
      "pattern": "nr-data.net",
      "patternKind": "domainSuffix",
      "organization": "New Relic",
      "sdkFamily": "New Relic Mobile",
      "categories": [
        "telemetry"
      ],
      "purposes": [
        "Application performance monitoring"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.newrelic"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.sentry.io",
      "pattern": "sentry.io",
      "patternKind": "domainSuffix",
      "organization": "Functional Software (Sentry)",
      "sdkFamily": "Sentry",
      "categories": [
        "crashReporting",
        "telemetry"
      ],
      "purposes": [
        "Error and crash reporting"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.sentry"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.bugsnag.com",
      "pattern": "bugsnag.com",
      "patternKind": "domainSuffix",
      "organization": "SmartBear (Bugsnag)",
      "sdkFamily": "Bugsnag",
      "categories": [
        "crashReporting"
      ],
      "purposes": [
        "Error and crash reporting"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.bugsnag"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.onesignal.com",
      "pattern": "onesignal.com",
      "patternKind": "domainSuffix",
      "organization": "OneSignal",
      "sdkFamily": "OneSignal",
      "categories": [
        "pushNotifications",
        "messaging"
      ],
      "purposes": [
        "Push notification delivery"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.onesignal"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.braze.com",
      "pattern": "braze.com",
      "patternKind": "domainSuffix",
      "organization": "Braze",
      "sdkFamily": "Braze",
      "categories": [
        "messaging",
        "personalization",
        "analytics"
      ],
      "purposes": [
        "Customer engagement messaging"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.braze"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.appboy.com",
      "pattern": "appboy.com",
      "patternKind": "domainSuffix",
      "organization": "Braze",
      "sdkFamily": "Braze",
      "categories": [
        "messaging",
        "personalization",
        "analytics"
      ],
      "purposes": [
        "Customer engagement messaging (legacy domain)"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.braze"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.iterable.com",
      "pattern": "iterable.com",
      "patternKind": "domainSuffix",
      "organization": "Iterable",
      "sdkFamily": "Iterable",
      "categories": [
        "messaging",
        "personalization"
      ],
      "purposes": [
        "Customer engagement messaging"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.iterable"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.clevertap.com",
      "pattern": "clevertap.com",
      "patternKind": "domainSuffix",
      "organization": "CleverTap",
      "sdkFamily": "CleverTap",
      "categories": [
        "analytics",
        "messaging",
        "personalization"
      ],
      "purposes": [
        "Engagement analytics and messaging"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.clevertap"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.push.apple.com",
      "pattern": "push.apple.com",
      "patternKind": "domainSuffix",
      "organization": "Apple",
      "sdkFamily": "Apple Push Notification service",
      "categories": [
        "pushNotifications"
      ],
      "purposes": [
        "Push notification delivery"
      ],
      "confidence": 0.95,
      "sourceIDs": [
        "src.apple.push"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Operating-system service; contact is expected on every device.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.cloudfront.net",
      "pattern": "cloudfront.net",
      "patternKind": "domainSuffix",
      "organization": "Amazon Web Services",
      "sdkFamily": "Amazon CloudFront",
      "categories": [
        "contentDelivery"
      ],
      "purposes": [
        "Content delivery network"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.aws.cloudfront"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Shared CDN: the destination says nothing about who operates the app behind it.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.akamaized.net",
      "pattern": "akamaized.net",
      "patternKind": "domainSuffix",
      "organization": "Akamai",
      "sdkFamily": "Akamai CDN",
      "categories": [
        "contentDelivery"
      ],
      "purposes": [
        "Content delivery network"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.akamai"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.akamai.net",
      "pattern": "akamai.net",
      "patternKind": "domainSuffix",
      "organization": "Akamai",
      "sdkFamily": "Akamai CDN",
      "categories": [
        "contentDelivery"
      ],
      "purposes": [
        "Content delivery network"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.akamai"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.fastly.net",
      "pattern": "fastly.net",
      "patternKind": "domainSuffix",
      "organization": "Fastly",
      "sdkFamily": "Fastly CDN",
      "categories": [
        "contentDelivery"
      ],
      "purposes": [
        "Content delivery network"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.fastly"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.cloudflare.com",
      "pattern": "cloudflare.com",
      "patternKind": "domainSuffix",
      "organization": "Cloudflare",
      "sdkFamily": "Cloudflare",
      "categories": [
        "contentDelivery"
      ],
      "purposes": [
        "Content delivery and security"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.cloudflare"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.stripe.com",
      "pattern": "stripe.com",
      "patternKind": "domainSuffix",
      "organization": "Stripe",
      "sdkFamily": "Stripe",
      "categories": [
        "payments"
      ],
      "purposes": [
        "Payment processing"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.stripe"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.paypal.com",
      "pattern": "paypal.com",
      "patternKind": "domainSuffix",
      "organization": "PayPal",
      "sdkFamily": "PayPal",
      "categories": [
        "payments"
      ],
      "purposes": [
        "Payment processing"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.paypal"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.auth0.com",
      "pattern": "auth0.com",
      "patternKind": "domainSuffix",
      "organization": "Okta (Auth0)",
      "sdkFamily": "Auth0",
      "categories": [
        "authentication"
      ],
      "purposes": [
        "Authentication"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.auth0"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.okta.com",
      "pattern": "okta.com",
      "patternKind": "domainSuffix",
      "organization": "Okta",
      "sdkFamily": "Okta",
      "categories": [
        "authentication"
      ],
      "purposes": [
        "Authentication"
      ],
      "confidence": 0.88,
      "sourceIDs": [
        "src.okta"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.sift.com",
      "pattern": "sift.com",
      "patternKind": "domainSuffix",
      "organization": "Sift",
      "sdkFamily": "Sift",
      "categories": [
        "fraudPrevention"
      ],
      "purposes": [
        "Fraud detection"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.sift"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.arkoselabs.com",
      "pattern": "arkoselabs.com",
      "patternKind": "domainSuffix",
      "organization": "Arkose Labs",
      "sdkFamily": "Arkose Labs",
      "categories": [
        "fraudPrevention"
      ],
      "purposes": [
        "Bot and fraud detection"
      ],
      "confidence": 0.86,
      "sourceIDs": [
        "src.arkose"
      ],
      "sourceType": "vendorDocumentation",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": null,
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.metricforge.example",
      "pattern": "metricforge.example",
      "patternKind": "domainSuffix",
      "organization": "MetricForge Demo",
      "sdkFamily": "MetricForge Demo",
      "categories": [
        "analytics",
        "telemetry"
      ],
      "purposes": [
        "Synthetic analytics vendor"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.adnexus-demo.example",
      "pattern": "adnexus-demo.example",
      "patternKind": "domainSuffix",
      "organization": "AdNexus Demo",
      "sdkFamily": "AdNexus Demo",
      "categories": [
        "advertising",
        "attribution"
      ],
      "purposes": [
        "Synthetic advertising vendor"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.audiencevault-demo.example",
      "pattern": "audiencevault-demo.example",
      "patternKind": "domainSuffix",
      "organization": "AudienceVault Demo",
      "sdkFamily": "AudienceVault Demo",
      "categories": [
        "dataBroker",
        "personalization"
      ],
      "purposes": [
        "Synthetic data broker"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.placegraph-demo.example",
      "pattern": "placegraph-demo.example",
      "patternKind": "domainSuffix",
      "organization": "PlaceGraph Demo",
      "sdkFamily": "PlaceGraph Demo",
      "categories": [
        "locationIntelligence"
      ],
      "purposes": [
        "Synthetic location intelligence vendor"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.attributekit-demo.example",
      "pattern": "attributekit-demo.example",
      "patternKind": "domainSuffix",
      "organization": "AttributeKit Demo",
      "sdkFamily": "AttributeKit Demo",
      "categories": [
        "attribution"
      ],
      "purposes": [
        "Synthetic attribution vendor"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.cdn-demo.example",
      "pattern": "cdn-demo.example",
      "patternKind": "domainSuffix",
      "organization": "CDN Demo",
      "sdkFamily": "CDN Demo",
      "categories": [
        "contentDelivery"
      ],
      "purposes": [
        "Synthetic content delivery network"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.loginid-demo.example",
      "pattern": "loginid-demo.example",
      "patternKind": "domainSuffix",
      "organization": "LoginID Demo",
      "sdkFamily": "LoginID Demo",
      "categories": [
        "authentication"
      ],
      "purposes": [
        "Synthetic authentication provider"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.stackwatch-demo.example",
      "pattern": "stackwatch-demo.example",
      "patternKind": "domainSuffix",
      "organization": "StackWatch Demo",
      "sdkFamily": "StackWatch Demo",
      "categories": [
        "crashReporting"
      ],
      "purposes": [
        "Synthetic crash reporting vendor"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    },
    {
      "id": "kb.riskguard-demo.example",
      "pattern": "riskguard-demo.example",
      "patternKind": "domainSuffix",
      "organization": "RiskGuard Demo",
      "sdkFamily": "RiskGuard Demo",
      "categories": [
        "fraudPrevention"
      ],
      "purposes": [
        "Synthetic fraud prevention vendor"
      ],
      "confidence": 0.9,
      "sourceIDs": [
        "src.demo"
      ],
      "sourceType": "internalReview",
      "firstSeen": "2026-08-31T00:00:00Z",
      "lastReviewed": "2026-08-31T00:00:00Z",
      "expiresAt": "2027-02-27T00:00:00Z",
      "reviewStatus": "reviewed",
      "geographicNotes": null,
      "falsePositiveNotes": "Synthetic entry for the bundled demo report. Not a real company.",
      "ruleAuthor": "Fire Privacy knowledge base",
      "changeReason": "Initial bundled dataset"
    }
  ]
}
"""#
}
