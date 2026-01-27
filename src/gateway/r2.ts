import type { Sandbox } from '@cloudflare/sandbox';
import type { ClawdbotEnv } from '../types';
import { R2_MOUNT_PATH } from '../config';

/**
 * Mount R2 bucket for persistent storage
 * 
 * @param sandbox - The sandbox instance
 * @param env - Worker environment bindings
 * @returns true if mounted successfully, false otherwise
 */
export async function mountR2Storage(sandbox: Sandbox, env: ClawdbotEnv): Promise<boolean> {
  // Skip if R2 credentials are not configured
  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY || !env.CF_ACCOUNT_ID) {
    console.log('R2 storage not configured (missing R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, or CF_ACCOUNT_ID)');
    return false;
  }

  try {
    console.log('Mounting R2 bucket at', R2_MOUNT_PATH);
    await sandbox.mountBucket('clawdbot-data', R2_MOUNT_PATH, {
      endpoint: `https://${env.CF_ACCOUNT_ID}.r2.cloudflarestorage.com`,
      // Pass credentials explicitly since we use R2_* naming instead of AWS_*
      credentials: {
        accessKeyId: env.R2_ACCESS_KEY_ID,
        secretAccessKey: env.R2_SECRET_ACCESS_KEY,
      },
    });
    console.log('R2 bucket mounted successfully - clawdbot data will persist across sessions');
    return true;
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    
    // "already in use" - bucket is already mounted, that's success
    if (errorMessage.includes('already in use')) {
      console.log('R2 bucket already mounted at', R2_MOUNT_PATH);
      return true;
    }
    
    // "not empty" - directory has files from previous sync but mount failed
    // This can happen after a container restart. The files are stale but
    // the sync will overwrite them. We return true so sync can proceed.
    if (errorMessage.includes('not empty') || errorMessage.includes('nonempty')) {
      console.log('R2 mount directory not empty, clearing and retrying...');
      // Try to clear the directory and mount again
      try {
        await sandbox.startProcess(`rm -rf ${R2_MOUNT_PATH}/*`);
        await sandbox.mountBucket('clawdbot-data', R2_MOUNT_PATH, {
          endpoint: `https://${env.CF_ACCOUNT_ID}.r2.cloudflarestorage.com`,
          credentials: {
            accessKeyId: env.R2_ACCESS_KEY_ID!,
            secretAccessKey: env.R2_SECRET_ACCESS_KEY!,
          },
        });
        console.log('R2 bucket mounted successfully after clearing directory');
        return true;
      } catch (retryErr) {
        const retryMessage = retryErr instanceof Error ? retryErr.message : String(retryErr);
        if (retryMessage.includes('already in use')) {
          console.log('R2 bucket already mounted at', R2_MOUNT_PATH);
          return true;
        }
        console.error('Failed to mount R2 bucket after retry:', retryErr);
        return false;
      }
    }
    
    // Don't fail if mounting fails - clawdbot can still run without persistent storage
    console.error('Failed to mount R2 bucket:', err);
    return false;
  }
}
