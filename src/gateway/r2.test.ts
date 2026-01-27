import { describe, it, expect, vi, beforeEach } from 'vitest';
import { mountR2Storage } from './r2';
import type { Sandbox } from '@cloudflare/sandbox';
import type { ClawdbotEnv } from '../types';

// Helper to create a minimal env object
function createEnv(overrides: Partial<ClawdbotEnv> = {}): ClawdbotEnv {
  return {
    Sandbox: {} as any,
    ASSETS: {} as any,
    CLAWDBOT_BUCKET: {} as any,
    ...overrides,
  };
}

// Helper to create a mock sandbox
function createMockSandbox(): { sandbox: Sandbox; mountBucketMock: ReturnType<typeof vi.fn> } {
  const mountBucketMock = vi.fn().mockResolvedValue(undefined);
  const sandbox = {
    mountBucket: mountBucketMock,
    listProcesses: vi.fn(),
    startProcess: vi.fn(),
    containerFetch: vi.fn(),
    wsConnect: vi.fn(),
  } as unknown as Sandbox;

  return { sandbox, mountBucketMock };
}

describe('mountR2Storage', () => {
  beforeEach(() => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('returns false when R2_ACCESS_KEY_ID is missing', async () => {
    const { sandbox } = createMockSandbox();
    const env = createEnv({
      R2_SECRET_ACCESS_KEY: 'secret',
      CF_ACCOUNT_ID: 'account123',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(false);
  });

  it('returns false when R2_SECRET_ACCESS_KEY is missing', async () => {
    const { sandbox } = createMockSandbox();
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      CF_ACCOUNT_ID: 'account123',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(false);
  });

  it('returns false when CF_ACCOUNT_ID is missing', async () => {
    const { sandbox } = createMockSandbox();
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      R2_SECRET_ACCESS_KEY: 'secret',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(false);
  });

  it('returns false when all R2 credentials are missing', async () => {
    const { sandbox } = createMockSandbox();
    const env = createEnv();

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(false);
    expect(console.log).toHaveBeenCalledWith(
      expect.stringContaining('R2 storage not configured')
    );
  });

  it('mounts R2 bucket when all credentials are provided', async () => {
    const { sandbox, mountBucketMock } = createMockSandbox();
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      R2_SECRET_ACCESS_KEY: 'secret',
      CF_ACCOUNT_ID: 'account123',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(true);
    expect(mountBucketMock).toHaveBeenCalledWith(
      'clawdbot-data',
      '/data/clawdbot',
      {
        endpoint: 'https://account123.r2.cloudflarestorage.com',
        credentials: {
          accessKeyId: 'key123',
          secretAccessKey: 'secret',
        },
      }
    );
  });

  it('returns false when mountBucket throws an error', async () => {
    const { sandbox, mountBucketMock } = createMockSandbox();
    mountBucketMock.mockRejectedValue(new Error('Mount failed'));
    
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      R2_SECRET_ACCESS_KEY: 'secret',
      CF_ACCOUNT_ID: 'account123',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(false);
    expect(console.error).toHaveBeenCalledWith(
      'Failed to mount R2 bucket:',
      expect.any(Error)
    );
  });

  it('returns true when bucket is already mounted', async () => {
    const { sandbox, mountBucketMock } = createMockSandbox();
    mountBucketMock.mockRejectedValue(new Error('InvalidMountConfigError: Mount path "/data/clawdbot" is already in use by bucket "clawdbot-data"'));
    
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      R2_SECRET_ACCESS_KEY: 'secret',
      CF_ACCOUNT_ID: 'account123',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(true);
    expect(console.log).toHaveBeenCalledWith(
      'R2 bucket already mounted at',
      '/data/clawdbot'
    );
  });

  it('logs success message when mounted successfully', async () => {
    const { sandbox } = createMockSandbox();
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      R2_SECRET_ACCESS_KEY: 'secret',
      CF_ACCOUNT_ID: 'account123',
    });

    await mountR2Storage(sandbox, env);

    expect(console.log).toHaveBeenCalledWith(
      'R2 bucket mounted successfully - clawdbot data will persist across sessions'
    );
  });

  it('clears directory and retries when mount fails due to non-empty directory', async () => {
    const { sandbox, mountBucketMock } = createMockSandbox();
    const startProcessMock = sandbox.startProcess as ReturnType<typeof vi.fn>;
    
    // First mount fails with "not empty", second succeeds
    mountBucketMock
      .mockRejectedValueOnce(new Error('S3FSMountError: S3FS mount failed: s3fs: MOUNTPOINT directory /data/clawdbot is not empty'))
      .mockResolvedValueOnce(undefined);
    
    startProcessMock.mockResolvedValue({ status: 'completed' });
    
    const env = createEnv({
      R2_ACCESS_KEY_ID: 'key123',
      R2_SECRET_ACCESS_KEY: 'secret',
      CF_ACCOUNT_ID: 'account123',
    });

    const result = await mountR2Storage(sandbox, env);

    expect(result).toBe(true);
    expect(startProcessMock).toHaveBeenCalledWith('rm -rf /data/clawdbot/*');
    expect(mountBucketMock).toHaveBeenCalledTimes(2);
  });
});
