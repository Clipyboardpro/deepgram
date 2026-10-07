export interface TranscriptWord {
  text: string;
  display?: string;
  start: number;
  end: number;
  confidence?: number;
}
export interface Transcript {
  schemaVersion: 1;
  provider: string;
  model: string;
  language: string;
  durationSeconds: number;
  words: TranscriptWord[];
}
export interface Submission {
  jobId: string;
  audioUrl: string;
  callbackUrl: string;
  language: string;
}
export interface ProviderSubmission {
  requestId: string;
}
export interface ProviderCallback {
  requestId: string;
  eventKey: string;
  status: "succeeded" | "failed";
  transcript?: Transcript;
  errorCode?: string;
}
export interface TranscriptionProvider {
  readonly name: string;
  readonly model: string;
  submit(input: Submission): Promise<ProviderSubmission>;
  result(requestId: string): Promise<Transcript>;
  parseCallback?(body: unknown, language: string): ProviderCallback;
}

/** Ağ çağrısı yapmaz. Dispatcher bu sonucu CX-003'te teslim eder. */
export class FakeProvider implements TranscriptionProvider {
  readonly name = "fake";
  readonly model = "fake-v1";
  submit(input: Submission): Promise<ProviderSubmission> {
    return Promise.resolve({ requestId: "fake:" + input.jobId });
  }
  result(_requestId: string): Promise<Transcript> {
    // Her çağrı bağımsız nesne döndürür; önceki sonucu değiştirmek diğer işleri etkilemez.
    return Promise.resolve({
      schemaVersion: 1,
      provider: this.name,
      model: this.model,
      language: "tr",
      durationSeconds: 1,
      words: [{
        text: "merhaba",
        display: "Merhaba,",
        start: 0.12,
        end: 0.48,
        confidence: 0.98,
      }],
    });
  }
}
