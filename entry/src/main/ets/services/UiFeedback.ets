import { common } from '@kit.AbilityKit';
import { publicFailure, redactDiagnosticText } from '../core/UserFacingCopy';
import { StatusStore } from './StatusStore';

export const UI_FEEDBACK_FILE: string = 'ui-feedback.json';

export class UiFeedback {
  static failure(context: common.Context | null, operation: string, error: Object, fallback: string): string {
    const rec = error as Record<string, Object>;
    const message = typeof rec['message'] === 'string' ? rec['message'] as string : '';
    const code = typeof rec['code'] === 'number' ? rec['code'] as number : 0;
    if (context !== null) {
      try {
        const record: Record<string, Object> = {};
        record['at'] = Date.now();
        record['operation'] = operation;
        record['code'] = code;
        record['detail'] = redactDiagnosticText(message);
        StatusStore.writeText(context, UI_FEEDBACK_FILE, JSON.stringify(record));
      } catch (_error) {
        // Feedback must never interrupt the user's original action.
      }
    }
    return publicFailure(message, fallback);
  }
}
