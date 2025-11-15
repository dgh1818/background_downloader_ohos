import { collections } from '@kit.ArkTS';

export interface AuthInit {
  readonly accessToken?: string;
  readonly accessHeaders?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string>;
  readonly accessQueryParams?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string>;
  readonly accessTokenExpiryTime?: number;
  readonly refreshToken?: string;
  readonly refreshHeaders?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string>;
  readonly refreshQueryParams?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string>;
  readonly refreshUrl?: string;
  readonly onAuthRawHandle?: number;
}

export interface AuthJSON {
  readonly accessToken: string | null;
  readonly accessHeaders: Record<string, string>;
  readonly accessQueryParams: Record<string, string>;
  readonly accessTokenExpiryTime: number | null;
  readonly refreshToken: string | null;
  readonly refreshHeaders: Record<string, string>;
  readonly refreshQueryParams: Record<string, string>;
  readonly refreshUrl: string | null;
  readonly onAuthRawHandle: number | null;
}

@Sendable
export class Auth {
  private accessToken?: string;
  private accessHeaders: Map<string, string>;
  private accessQueryParams: Map<string, string>;
  private accessTokenExpiryTime?: number;
  private refreshToken?: string;
  private refreshHeaders: Map<string, string>;
  private refreshQueryParams: Map<string, string>;
  private refreshUrl?: string;
  private onAuthRawHandle?: number;

  constructor(init?: AuthInit) {
    this.accessToken = init?.accessToken ?? undefined;
    this.accessHeaders = Auth.copyStringMap(init?.accessHeaders);
    this.accessQueryParams = Auth.copyStringMap(init?.accessQueryParams);
    this.accessTokenExpiryTime = init?.accessTokenExpiryTime ?? undefined;
    this.refreshToken = init?.refreshToken ?? undefined;
    this.refreshHeaders = Auth.copyStringMap(init?.refreshHeaders);
    this.refreshQueryParams = Auth.copyStringMap(init?.refreshQueryParams);
    this.refreshUrl = init?.refreshUrl ?? undefined;
    this.onAuthRawHandle = init?.onAuthRawHandle ?? undefined;
  }

  static from(init?: Auth | AuthInit | AuthJSON | null): Auth | undefined {
    if (!init) {
      return undefined;
    }
    if (init instanceof Auth) {
      return init;
    }
    const normalized: AuthInit = {
      accessToken: (init as { accessToken?: string | null }).accessToken ?? undefined,
      accessHeaders: (init as { accessHeaders?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string> }).accessHeaders,
      accessQueryParams: (init as { accessQueryParams?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string> }).accessQueryParams,
      accessTokenExpiryTime: (init as { accessTokenExpiryTime?: number | null }).accessTokenExpiryTime ?? undefined,
      refreshToken: (init as { refreshToken?: string | null }).refreshToken ?? undefined,
      refreshHeaders: (init as { refreshHeaders?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string> }).refreshHeaders,
      refreshQueryParams: (init as { refreshQueryParams?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string> }).refreshQueryParams,
      refreshUrl: (init as { refreshUrl?: string | null }).refreshUrl ?? undefined,
      onAuthRawHandle: (init as { onAuthRawHandle?: number | null }).onAuthRawHandle ?? undefined,
    };
    return new Auth(normalized);
  }

  private static copyStringMap(
    source?: Map<string, string> | Record<string, string | null | undefined> | collections.Map<string, string>,
  ): Map<string, string> {
    const result = new Map<string, string>();
    if (!source) {
      return result;
    }
    if (source instanceof Map) {
      source.forEach((value, key) => {
        if (value !== undefined && value !== null) {
          result.set(key, value);
        }
      });
      return result;
    }
    const maybeCollections = source as unknown as {
      forEach?: (callback: (value: string, key: string) => void) => void;
    };
    if (typeof maybeCollections.forEach === 'function') {
      maybeCollections.forEach((value, key) => {
        if (value !== undefined && value !== null) {
          result.set(key, value);
        }
      });
      return result;
    }
    Object.entries(source as Record<string, string | null | undefined>).forEach(([key, value]) => {
      if (value !== undefined && value !== null) {
        result.set(key, value);
      }
    });
    return result;
  }

  private expandMap(map: Map<string, string>): Map<string, string> {
    const expanded = new Map<string, string>();
    map.forEach((value, key) => {
      let newValue = value;
      if (this.accessToken !== undefined) {
        newValue = newValue.replace('{accessToken}', this.accessToken);
      }
      if (this.refreshToken !== undefined) {
        newValue = newValue.replace('{refreshToken}', this.refreshToken);
      }
      expanded.set(key, newValue);
    });
    return expanded;
  }

  getExpandedAccessHeaders(): Map<string, string> {
    return this.expandMap(this.accessHeaders);
  }

  getExpandedAccessQueryParams(): Map<string, string> {
    return this.expandMap(this.accessQueryParams);
  }

  addOrUpdateQueryParams(
    targetUrl: string,
    queryParams?: Map<string, string> | Record<string, string> | collections.Map<string, string>,
  ): string {
    const params = Auth.copyStringMap(queryParams);
    if (params.size === 0) {
      return targetUrl;
    }
    const hashIndex = targetUrl.indexOf('#');
    const fragment = hashIndex >= 0 ? targetUrl.substring(hashIndex) : '';
    const searchStartIndex = targetUrl.indexOf('?');
    const pathEnd = hashIndex >= 0 ? hashIndex : targetUrl.length;
    const base = searchStartIndex >= 0 ? targetUrl.substring(0, searchStartIndex) : targetUrl.substring(0, pathEnd);
    const existingQuery =
      searchStartIndex >= 0 ? targetUrl.substring(searchStartIndex + 1, pathEnd) : '';
    const merged = new Map<string, string>();

    if (existingQuery.length > 0) {
      const pairs = existingQuery.split('&');
      pairs.forEach((pair) => {
        if (!pair) {
          return;
        }
        const equalsIndex = pair.indexOf('=');
        let rawKey: string;
        let rawValue: string;
        if (equalsIndex >= 0) {
          rawKey = pair.substring(0, equalsIndex);
          rawValue = pair.substring(equalsIndex + 1);
        } else {
          rawKey = pair;
          rawValue = '';
        }
        let decodedKey: string;
        let decodedValue: string;
        try {
          decodedKey = decodeURIComponent(rawKey);
        } catch (_) {
          decodedKey = rawKey;
        }
        try {
          decodedValue = decodeURIComponent(rawValue);
        } catch (_) {
          decodedValue = rawValue;
        }
        merged.set(decodedKey, decodedValue);
      });
    }

    params.forEach((value, key) => {
      merged.set(key, value);
    });

    const queryString = Array.from(merged.entries())
      .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
      .join('&');

    if (queryString.length === 0) {
      return `${base}${fragment}`;
    }

    return `${base}?${queryString}${fragment}`;
  }

  isTokenExpired(bufferTime: number = 10000): boolean {
    if (this.accessTokenExpiryTime === undefined) {
      return false;
    }
    return Date.now() + bufferTime > this.accessTokenExpiryTime;
  }

  hasOnAuthCallback(): boolean {
    return this.onAuthRawHandle !== undefined && this.onAuthRawHandle !== null;
  }

  toJSON(): AuthJSON {
    return {
      accessToken: this.accessToken ?? null,
      accessHeaders: Auth.mapToRecord(this.accessHeaders),
      accessQueryParams: Auth.mapToRecord(this.accessQueryParams),
      accessTokenExpiryTime: this.accessTokenExpiryTime ?? null,
      refreshToken: this.refreshToken ?? null,
      refreshHeaders: Auth.mapToRecord(this.refreshHeaders),
      refreshQueryParams: Auth.mapToRecord(this.refreshQueryParams),
      refreshUrl: this.refreshUrl ?? null,
      onAuthRawHandle: this.onAuthRawHandle ?? null,
    };
  }

  private static mapToRecord(map: Map<string, string>): Record<string, string> {
    const record: Record<string, string> = {};
    map.forEach((value, key) => {
      record[key] = value;
    });
    return record;
  }
}
