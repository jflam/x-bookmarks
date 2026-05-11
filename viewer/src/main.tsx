import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { AlertTriangle, CheckCircle2, ExternalLink, Filter, Search } from "lucide-react";
import "./styles.css";

type Bookmark = {
  account_user_id: string;
  tweet_id: string;
  complete_for_offline_render: boolean;
  canonical_uri: string;
  twitter_uri: string;
  text: string;
  created_at: string;
  author_id: string;
  author_username: string;
  author_name: string;
  author_avatar_url: string;
  raw_json: string;
};

type TweetRecord = {
  tweet_id: string;
  canonical_uri: string;
  twitter_uri: string;
  text: string;
  created_at: string;
  author_id: string;
  author_username: string;
  author_name: string;
  raw_json: string;
};

type Folder = {
  account_user_id: string;
  folder_id: string;
  name: string;
  raw_json: string;
};

type MediaAsset = {
  media_key: string;
  asset_kind: string;
  source_url: string;
  local_path: string;
  viewer_path?: string;
  content_type: string;
  byte_size: number;
  sha256: string;
  width: number;
  height: number;
  status: string;
  error_json: string;
};

type RenderMediaItem = {
  mediaKey: string;
  image?: MediaAsset;
  poster?: MediaAsset;
  video?: MediaAsset;
};

type TweetMedia = {
  tweet_id: string;
  media_key: string;
  position: number;
};

type FolderItem = {
  account_user_id: string;
  folder_id: string;
  tweet_id: string;
};

type MissingReference = {
  tweet_id: string;
  referenced_tweet_id: string;
  reference_type: string;
  status: string;
  raw_json: string;
};

type Summary = {
  generated_at: string;
  total_bookmarks: number;
  new_bookmarks: number;
  complete_bookmarks: number;
  incomplete_bookmarks: number;
  failed_media_assets: number;
  skipped_media_assets: number;
  folders: number;
  quote_posts: number;
  sync_warnings: number;
};

const emptySummary: Summary = {
  generated_at: "",
  total_bookmarks: 0,
  new_bookmarks: 0,
  complete_bookmarks: 0,
  incomplete_bookmarks: 0,
  failed_media_assets: 0,
  skipped_media_assets: 0,
  folders: 0,
  quote_posts: 0,
  sync_warnings: 0
};

function App() {
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([]);
  const [tweets, setTweets] = useState<TweetRecord[]>([]);
  const [folders, setFolders] = useState<Folder[]>([]);
  const [assets, setAssets] = useState<MediaAsset[]>([]);
  const [tweetMedia, setTweetMedia] = useState<TweetMedia[]>([]);
  const [folderItems, setFolderItems] = useState<FolderItem[]>([]);
  const [missingReferences, setMissingReferences] = useState<MissingReference[]>([]);
  const [summary, setSummary] = useState<Summary>(emptySummary);
  const [query, setQuery] = useState("");
  const [complete, setComplete] = useState("all");
  const [assetState, setAssetState] = useState("all");
  const [folderFilter, setFolderFilter] = useState("all");

  useEffect(() => {
    void loadJson<Bookmark[]>("data/bookmarks.json", []).then(setBookmarks);
    void loadJson<TweetRecord[]>("data/tweets.json", []).then(setTweets);
    void loadJson<Folder[]>("data/folders.json", []).then(setFolders);
    void loadJson<MediaAsset[]>("data/media-assets.json", []).then(setAssets);
    void loadJson<TweetMedia[]>("data/tweet-media.json", []).then(setTweetMedia);
    void loadJson<FolderItem[]>("data/folder-items.json", []).then(setFolderItems);
    void loadJson<MissingReference[]>("data/missing-references.json", []).then(setMissingReferences);
    void loadJson<Summary>("data/sync-summary.json", emptySummary).then(setSummary);
  }, []);

  const failedAssetKeys = useMemo(() => new Set(assets.filter((asset) => asset.status === "failed").map((asset) => asset.media_key)), [assets]);
  const assetsByMediaKey = useMemo(() => groupBy(assets.filter((asset) => asset.status === "downloaded"), (asset) => asset.media_key), [assets]);
  const mediaByTweetId = useMemo(() => groupBy(tweetMedia, (item) => item.tweet_id), [tweetMedia]);
  const foldersByTweetId = useMemo(() => groupBy(folderItems, (item) => item.tweet_id), [folderItems]);
  const folderNames = useMemo(() => new Map(folders.map((folder) => [folder.folder_id, folder.name || folder.folder_id])), [folders]);
  const tweetsById = useMemo(() => new Map(tweets.map((tweet) => [tweet.tweet_id, tweet])), [tweets]);
  const missingByTweetId = useMemo(() => groupBy(missingReferences, (item) => item.tweet_id), [missingReferences]);
  const failedBookmarkIds = useMemo(() => {
    const ids = new Set<string>();
    for (const bookmark of bookmarks) {
      if (bookmarkHasFailedAsset(bookmark, failedAssetKeys, mediaByTweetId, tweetsById)) {
        ids.add(bookmark.tweet_id);
      }
    }
    return ids;
  }, [bookmarks, failedAssetKeys, mediaByTweetId, tweetsById]);

  const filtered = bookmarks.filter((bookmark) => {
    const displayText = fullTweetText(bookmark.text, bookmark.raw_json);
    const haystack = `${displayText} ${bookmark.author_username} ${bookmark.author_name}`.toLowerCase();
    if (query && !haystack.includes(query.toLowerCase())) return false;
    if (complete === "complete" && !bookmark.complete_for_offline_render) return false;
    if (complete === "incomplete" && bookmark.complete_for_offline_render) return false;
    if (assetState === "failed-assets" && !failedBookmarkIds.has(bookmark.tweet_id)) return false;
    if (folderFilter !== "all" && !(foldersByTweetId.get(bookmark.tweet_id) || []).some((item) => item.folder_id === folderFilter)) return false;
    return true;
  });

  return (
    <>
      <header className="topbar">
        <div>
          <h1>x-bookmarks</h1>
          <p>{summary.total_bookmarks} bookmarks, {summary.complete_bookmarks} complete</p>
        </div>
        <label className="control">
          <Search size={16} />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search bookmarks" />
        </label>
        <label className="control">
          <Filter size={16} />
          <select value={complete} onChange={(event) => setComplete(event.target.value)}>
            <option value="all">All completeness</option>
            <option value="complete">Complete</option>
            <option value="incomplete">Incomplete</option>
          </select>
        </label>
        <label className="control">
          <AlertTriangle size={16} />
          <select value={assetState} onChange={(event) => setAssetState(event.target.value)}>
            <option value="all">All assets</option>
            <option value="failed-assets">Failed assets</option>
          </select>
        </label>
        <label className="control">
          <Filter size={16} />
          <select value={folderFilter} onChange={(event) => setFolderFilter(event.target.value)}>
            <option value="all">All folders</option>
            {folders.map((folder) => (
              <option key={folder.folder_id} value={folder.folder_id}>{folder.name || folder.folder_id}</option>
            ))}
          </select>
        </label>
      </header>

      <main>
        <section className="summary">
          <Stat label="New" value={summary.new_bookmarks} />
          <Stat label="Incomplete" value={summary.incomplete_bookmarks} />
          <Stat label="Failed Media" value={summary.failed_media_assets} />
          <Stat label="Skipped Media" value={summary.skipped_media_assets} />
          <Stat label="Folders" value={folders.length || summary.folders} />
          <Stat label="Quote Posts" value={summary.quote_posts} />
          <Stat label="Warnings" value={summary.sync_warnings} />
        </section>

        {filtered.map((bookmark) => {
          const displayText = fullTweetText(bookmark.text, bookmark.raw_json);
          return (
            <article className="tweet" key={`${bookmark.account_user_id}-${bookmark.tweet_id}`}>
              <div className="tweet-head">
                <Avatar
                  name={bookmark.author_name || bookmark.author_username}
                  src={avatarForAuthor(bookmark.author_id, assetsByMediaKey)}
                />
                <div>
                  <div className="name-row">
                    <strong>{bookmark.author_name || "Unknown author"}</strong>
                    <span>@{bookmark.author_username || "unknown"}</span>
                    {bookmark.complete_for_offline_render ? <CheckCircle2 size={16} className="ok" /> : <AlertTriangle size={16} className="warn" />}
                  </div>
                  <time>{bookmark.created_at || "No timestamp"}</time>
                </div>
              </div>
              <p className="tweet-text"><TweetText text={displayText} rawJson={bookmark.raw_json} /></p>
              <QuotePost
                tweet={quoteForBookmark(bookmark, tweetsById)}
                assetsByMediaKey={assetsByMediaKey}
                mediaByTweetId={mediaByTweetId}
              />
              <MissingQuotes refs={missingByTweetId.get(bookmark.tweet_id) || []} />
              <MediaGallery media={mediaForBookmark(bookmark, mediaByTweetId, assetsByMediaKey)} />
              <div className="folder-row">
                {(foldersByTweetId.get(bookmark.tweet_id) || []).map((item) => <span key={item.folder_id}>{folderNames.get(item.folder_id) || item.folder_id}</span>)}
              </div>
              <div className="link-row">
                <a href={bookmark.canonical_uri}><ExternalLink size={14} /> X URI</a>
                <a href={bookmark.twitter_uri}><ExternalLink size={14} /> Twitter URI</a>
              </div>
              <details>
                <summary>Raw JSON</summary>
                <pre>{bookmark.raw_json}</pre>
              </details>
            </article>
          );
        })}

        {filtered.length === 0 && <p className="empty">No bookmarks match the current filters.</p>}
      </main>
    </>
  );
}

function MissingQuotes({ refs }: { refs: MissingReference[] }) {
  const quoteRefs = refs.filter((ref) => ref.reference_type === "quoted");
  if (quoteRefs.length === 0) return null;
  return (
    <div className="quote missing">
      {quoteRefs.map((ref) => (
        <p key={ref.referenced_tweet_id}>Quoted post {ref.status || "unavailable"}: {ref.referenced_tweet_id}</p>
      ))}
    </div>
  );
}

function TweetText({ text, rawJson }: { text: string; rawJson: string }) {
  const entities = urlEntitiesFromRawJson(rawJson);
  if (entities.length === 0) return <>{text}</>;

  const nodes: React.ReactNode[] = [];
  let remaining = text;
  let key = 0;
  for (const entity of entities) {
    const index = remaining.indexOf(entity.url);
    if (index < 0) continue;
    if (index > 0) nodes.push(remaining.slice(0, index));
    nodes.push(
      <a key={`url-${key++}`} href={entity.expanded_url || entity.url}>
        {entity.display_url || entity.expanded_url || entity.url}
      </a>
    );
    remaining = remaining.slice(index + entity.url.length);
  }
  nodes.push(remaining);
  return <>{nodes}</>;
}

function fullTweetText(fallback: string, rawJson: string) {
  try {
    const raw = JSON.parse(rawJson) as { note_tweet?: { text?: string }; text?: string };
    return raw.note_tweet?.text || raw.text || fallback;
  } catch {
    return fallback;
  }
}

type UrlEntity = {
  url: string;
  expanded_url?: string;
  display_url?: string;
};

function urlEntitiesFromRawJson(rawJson: string): UrlEntity[] {
  try {
    const raw = JSON.parse(rawJson) as { entities?: { urls?: UrlEntity[] } };
    return Array.isArray(raw.entities?.urls)
      ? raw.entities.urls.filter((entity) => entity.url)
      : [];
  } catch {
    return [];
  }
}

function QuotePost({ tweet, mediaByTweetId, assetsByMediaKey }: { tweet?: TweetRecord; mediaByTweetId: Map<string, TweetMedia[]>; assetsByMediaKey: Map<string, MediaAsset[]> }) {
  if (!tweet) return null;
  return (
    <div className="quote">
      <div className="name-row">
        <Avatar name={tweet.author_name || tweet.author_username} src={avatarForAuthor(tweet.author_id, assetsByMediaKey)} compact />
        <strong>{tweet.author_name || "Unknown author"}</strong>
        <span>@{tweet.author_username || "unknown"}</span>
      </div>
      <p className="quote-text"><TweetText text={fullTweetText(tweet.text, tweet.raw_json)} rawJson={tweet.raw_json} /></p>
      <MediaGallery media={mediaForTweet(tweet.tweet_id, mediaByTweetId, assetsByMediaKey)} />
      <a href={tweet.canonical_uri}><ExternalLink size={14} /> Quoted post</a>
    </div>
  );
}

function MediaGallery({ media }: { media: MediaAsset[] }) {
  const items = mediaGalleryItems(media);
  if (items.length === 0) return null;
  return (
    <div className="media-grid">
      {items.map((item) => {
        if (item.video) {
          return (
            <video
              key={`${item.mediaKey}-${item.video.local_path}`}
              src={assetSrc(item.video)}
              poster={item.poster ? assetSrc(item.poster) : undefined}
              controls
              playsInline
              preload="metadata"
            />
          );
        }
        if (item.image) return <img key={`${item.mediaKey}-${item.image.local_path}`} src={assetSrc(item.image)} alt="" loading="lazy" />;
        return null;
      })}
    </div>
  );
}

function mediaGalleryItems(media: MediaAsset[]): RenderMediaItem[] {
  const byKey = groupBy(media, (asset) => asset.media_key);
  return Array.from(byKey.entries()).flatMap<RenderMediaItem>(([mediaKey, assets]) => {
    const video = bestVideoAsset(assets);
    const poster = bestPosterAsset(assets);
    const image = bestImageAsset(assets);
    if (video) return [{ mediaKey, video, poster }];
    if (image) return [{ mediaKey, image }];
    return [];
  });
}

function bestVideoAsset(assets: MediaAsset[]) {
  return assets
    .filter((asset) => asset.asset_kind.includes("video") || asset.local_path.endsWith(".mp4"))
    .sort((a, b) => usableByteSize(a) - usableByteSize(b))[0];
}

function bestPosterAsset(assets: MediaAsset[]) {
  return assets.find((asset) => asset.asset_kind === "preview_image") || assets.find((asset) => asset.asset_kind === "image");
}

function bestImageAsset(assets: MediaAsset[]) {
  return assets.find((asset) => asset.asset_kind === "image") || assets.find((asset) => asset.asset_kind === "preview_image");
}

function usableByteSize(asset: MediaAsset) {
  return asset.byte_size > 0 ? asset.byte_size : Number.MAX_SAFE_INTEGER;
}

function assetSrc(asset: MediaAsset) {
  return asset.viewer_path || asset.local_path;
}

function mediaForBookmark(bookmark: Bookmark, mediaByTweetId: Map<string, TweetMedia[]>, assetsByMediaKey: Map<string, MediaAsset[]>) {
  return mediaForTweet(bookmark.tweet_id, mediaByTweetId, assetsByMediaKey);
}

function mediaForTweet(tweetId: string, mediaByTweetId: Map<string, TweetMedia[]>, assetsByMediaKey: Map<string, MediaAsset[]>) {
  const keys = mediaByTweetId.get(tweetId) || [];
  return keys.flatMap((item) => assetsByMediaKey.get(item.media_key) || []);
}

function avatarForAuthor(authorId: string, assetsByMediaKey: Map<string, MediaAsset[]>) {
  if (!authorId) return undefined;
  return (assetsByMediaKey.get(`user:${authorId}`) || []).find((asset) => asset.asset_kind === "author_avatar")?.viewer_path;
}

function quoteForBookmark(bookmark: Bookmark, tweetsById: Map<string, TweetRecord>) {
  try {
    const raw = JSON.parse(bookmark.raw_json);
    const refs = Array.isArray(raw.referenced_tweets) ? raw.referenced_tweets : [];
    const quote = refs.find((ref: { type?: string; id?: string }) => ref.type === "quoted" && ref.id);
    return quote?.id ? tweetsById.get(quote.id) : undefined;
  } catch {
    return undefined;
  }
}

function bookmarkHasFailedAsset(bookmark: Bookmark, failedAssetKeys: Set<string>, mediaByTweetId: Map<string, TweetMedia[]>, tweetsById: Map<string, TweetRecord>) {
  if (failedAssetKeys.has(`user:${bookmark.author_id}`)) return true;
  if ((mediaByTweetId.get(bookmark.tweet_id) || []).some((item) => failedAssetKeys.has(item.media_key))) return true;
  const quote = quoteForBookmark(bookmark, tweetsById);
  if (!quote) return false;
  if (failedAssetKeys.has(`user:${quote.author_id}`)) return true;
  return (mediaByTweetId.get(quote.tweet_id) || []).some((item) => failedAssetKeys.has(item.media_key));
}

function groupBy<T>(items: T[], keyFn: (item: T) => string) {
  const map = new Map<string, T[]>();
  for (const item of items) {
    const key = keyFn(item);
    const existing = map.get(key);
    if (existing) existing.push(item);
    else map.set(key, [item]);
  }
  return map;
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="stat">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function Avatar({ name, src, compact = false }: { name: string; src?: string; compact?: boolean }) {
  if (src) return <img className={compact ? "avatar compact" : "avatar"} src={src} alt="" loading="lazy" />;
  return <div className={compact ? "avatar compact" : "avatar"}>{initials(name)}</div>;
}

function initials(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return "?";
  return trimmed.slice(0, 2).toUpperCase();
}

async function loadJson<T>(path: string, fallback: T): Promise<T> {
  try {
    const response = await fetch(path);
    if (!response.ok) return fallback;
    return await response.json() as T;
  } catch {
    return fallback;
  }
}

createRoot(document.getElementById("root")!).render(<App />);
