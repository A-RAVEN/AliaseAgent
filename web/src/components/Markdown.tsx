// Markdown 渲染叶子（Markdown 由 web-core-shim 规范要求保留）。
import ReactMarkdown from 'react-markdown';

export function Markdown({ text }: { text: string }) {
  return (
    <div className="markdown-body">
      <ReactMarkdown>{text}</ReactMarkdown>
    </div>
  );
}
