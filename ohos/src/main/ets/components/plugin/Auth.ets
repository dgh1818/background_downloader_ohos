import { collections } from "@kit.ArkTS";

@Sendable
export class Auth {
  public accessToken?: string;
  public accessHeaders: collections.Map<string, string>;
  public accessQueryParams: collections.Map<string, string>;
  public accessTokenExpiryTime?: number;
  public refreshToken?: string;
  public refreshHeaders: collections.Map<string, string>;
  public refreshQueryParams: collections.Map<string, string>;
  public refreshUrl?: string;
  public onAuthRawHandle?: number;

  constructor(accessHeaders: collections.Map<string, string>,accessQueryParams: collections.Map<string, string>,refreshHeaders: collections.Map<string, string>,refreshQueryParams: collections.Map<string, string>,accessToken?: string,accessTokenExpiryTime?: number,refreshToken?: string,refreshUrl?: string,onAuthRawHandle?: number) {
    this.accessToken = accessToken;
    this.accessHeaders = accessHeaders;
    this.accessQueryParams = accessQueryParams;
    this.accessTokenExpiryTime = accessTokenExpiryTime;
    this.refreshToken = refreshToken;
    this.refreshHeaders = refreshHeaders
    this.refreshQueryParams = refreshQueryParams;
    this.refreshUrl = refreshUrl;
    this.onAuthRawHandle = onAuthRawHandle;
  }

  private expandMap(map: collections.Map<string, string>): collections.Map<string, string> {
    const expanded = new collections.Map<string, string>();
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

  getExpandedAccessHeaders(): collections.Map<string, string> {
    return this.expandMap(this.accessHeaders);
  }

  getExpandedAccessQueryParams(): collections.Map<string, string> {
    return this.expandMap(this.accessQueryParams);
  }

  addOrUpdateQueryParams(
    targetUrl: string,
    queryParams?: collections.Map<string, string>
  ): string {


    let hasParams = false;
    if(queryParams) {
      queryParams.forEach(() => {
        hasParams = true;
      });
    }

    if (!hasParams) {
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

    if(queryParams) {
      queryParams.forEach((value, key) => {
        merged.set(key, value);
      });
    }

    const mergedEntries = Array.from(merged.entries());
    const encodedParts: Array<string> = [];
    for (let i = 0; i < mergedEntries.length; i++) {
      const entry = mergedEntries[i];
      const key = entry[0];
      const value = entry[1];
      encodedParts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    }
    const queryString = encodedParts.join('&');

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
}

