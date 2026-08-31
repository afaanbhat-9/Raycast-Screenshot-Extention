import { getPreferenceValues, environment } from '@raycast/api';
import { execFile } from 'child_process';
import { promisify } from 'util';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { captureScreenshot, CaptureMode } from './screenshot';

const execFileAsync = promisify(execFile);

export interface OcrResult {
  success: boolean;
  text?: string;
  message?: string;
}

let cachedOcrExePath: string | null = null;

export function getOcrExePath(): string | null {
  if (cachedOcrExePath && fs.existsSync(cachedOcrExePath)) {
    return cachedOcrExePath;
  }
  cachedOcrExePath = null;

  const candidates: (string | undefined)[] = [
    environment.assetsPath ? path.join(environment.assetsPath, 'bin', 'ocr.exe') : undefined,
    path.join(process.cwd(), 'assets', 'bin', 'ocr.exe'),
    path.join(__dirname, '..', 'assets', 'bin', 'ocr.exe'),
    path.join(__dirname, '..', '..', 'assets', 'bin', 'ocr.exe'),
    path.join(__dirname, 'assets', 'bin', 'ocr.exe'),
  ];

  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) {
      cachedOcrExePath = candidate;
      return candidate;
    }
  }

  return null;
}

export function getOcrScriptPath(): string | null {
  const candidates: (string | undefined)[] = [
    environment.assetsPath ? path.join(environment.assetsPath, 'scripts', 'ocr.ps1') : undefined,
    path.join(process.cwd(), 'assets', 'scripts', 'ocr.ps1'),
    path.join(__dirname, '..', 'assets', 'scripts', 'ocr.ps1'),
    path.join(__dirname, '..', '..', 'assets', 'scripts', 'ocr.ps1'),
    path.join(__dirname, 'assets', 'scripts', 'ocr.ps1'),
  ];

  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return null;
}

export async function processImageOcr(imagePath: string): Promise<OcrResult> {
  if (!imagePath || !fs.existsSync(imagePath)) {
    return {
      success: false,
      message: `Image file not found at path: ${imagePath || '(empty)'}`,
    };
  }

  const ocrExePath = getOcrExePath();

  if (ocrExePath && fs.existsSync(ocrExePath)) {
    try {
      const { stdout } = await execFileAsync(ocrExePath, ['-ImagePath', imagePath], {
        windowsHide: true,
        timeout: 15000,
      });

      const output = stdout.trim();

      if (output.startsWith('SUCCESS|TEXT|')) {
        const text = output.substring('SUCCESS|TEXT|'.length).trim();
        return {
          success: true,
          text,
        };
      }

      if (output.startsWith('SUCCESS|NO_TEXT')) {
        return {
          success: true,
          text: '',
          message: 'No readable text found in image',
        };
      }

      if (output.startsWith('ERROR|')) {
        const errorMsg = output.substring('ERROR|'.length).trim();
        return {
          success: false,
          message: errorMsg || 'Failed to extract text from image',
        };
      }
    } catch {
      // Fall back to ocr.ps1 if native execution fails
    }
  }

  const scriptPath = getOcrScriptPath();
  if (!scriptPath || !fs.existsSync(scriptPath)) {
    return {
      success: false,
      message: `OCR engine binary and script not found.`,
    };
  }

  try {
    const { stdout } = await execFileAsync(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, '-ImagePath', imagePath],
      { timeout: 30000 },
    );

    const output = stdout.trim();

    if (output.startsWith('SUCCESS|TEXT|')) {
      const text = output.substring('SUCCESS|TEXT|'.length).trim();
      return {
        success: true,
        text,
      };
    }

    if (output.startsWith('SUCCESS|NO_TEXT')) {
      return {
        success: true,
        text: '',
        message: 'No readable text found in image',
      };
    }

    if (output.startsWith('ERROR|')) {
      const errorMsg = output.substring('ERROR|'.length).trim();
      return {
        success: false,
        message: errorMsg || 'Failed to extract text from image',
      };
    }

    return {
      success: false,
      message: `Unexpected output from OCR process: ${output || '(empty stdout)'}`,
    };
  } catch (error) {
    const err = error as Error;
    return {
      success: false,
      message: `PowerShell OCR execution error: ${err.message}`,
    };
  }
}

export async function captureAndExtractText(
  mode: CaptureMode = 'region',
): Promise<OcrResult & { cancelled?: boolean }> {
  const preferences = getPreferenceValues<{ output?: string }>();
  const outputMode = preferences.output || 'save-and-copy';
  const isCopyOnly = outputMode === 'copy';

  const captureRes = await captureScreenshot(mode, {
    forceSave: true,
    overrideSavePath: isCopyOnly ? os.tmpdir() : undefined,
  });

  if (captureRes.cancelled) {
    return { success: false, cancelled: true };
  }

  if (!captureRes.success || !captureRes.filePath) {
    return {
      success: false,
      message: captureRes.error || 'Failed to capture screenshot for OCR',
    };
  }

  const tempFilePath = captureRes.filePath;

  try {
    if (fs.existsSync(tempFilePath)) {
      const ocrRes = await processImageOcr(tempFilePath);
      return ocrRes;
    }

    return {
      success: false,
      message: `Captured image file not found on disk: ${tempFilePath}`,
    };
  } finally {
    if (isCopyOnly && fs.existsSync(tempFilePath)) {
      try {
        fs.unlinkSync(tempFilePath);
      } catch {
        // Safe cleanup of temporary OCR file
      }
    }
  }
}
