import Link from 'next/link';
import { appName, githubUrl } from '@/lib/shared';
import { i18n } from '@/lib/i18n';

export function generateStaticParams() {
  return i18n.languages.map((lang) => ({ lang }));
}

const copy = {
  en: {
    tagline: 'A content framework for Palworld',
    lead: 'Declare pals, items, buildings, skills, effects, sounds, meshes and UI in Lua. Every domain has the same three-member surface, every field is validated, and every lifecycle hook says plainly whether it fires yet.',
    start: 'Get started',
    reference: 'API reference',
    github: 'View on GitHub',
    exampleTitle: 'One definition, start to finish',
    features: [
      {
        title: 'One shape per domain',
        body: 'Call the module to define, `get(id)` for an existing one, `get_all()` for every registered one. Pal, Item, Building, Skill, Effect, Audio, Mesh and UI all work the same way.',
      },
      {
        title: 'Typos are errors, not silence',
        body: 'Every field is declared as data and checked on every call. An unknown field fails immediately with a did-you-mean suggestion, and the editor completes the same field list.',
      },
      {
        title: 'An honest lifecycle',
        body: 'Each hook is marked LIVE or declarable. If no native game event drives a hook yet, the docs say so instead of letting you write code that never runs.',
      },
    ],
  },
  ja: {
    tagline: 'Palworld 向けコンテンツフレームワーク',
    lead: 'パル・アイテム・建築物・スキル・効果・サウンド・メッシュ・UI を Lua で宣言します。すべてのドメインが同じ 3 つの入口を持ち、すべてのフィールドが検証され、ライフサイクルフックは実際に発火するかどうかを明示します。',
    start: 'はじめる',
    reference: 'API リファレンス',
    github: 'GitHub で見る',
    exampleTitle: '定義から実行まで',
    features: [
      {
        title: 'ドメインごとに同じ形',
        body: 'モジュールを呼べば定義、`get(id)` で既存のものを取得、`get_all()` で登録済みの一覧。Pal / Item / Building / Skill / Effect / Audio / Mesh / UI がすべて同じ形です。',
      },
      {
        title: 'タイポは黙って無視されない',
        body: 'すべてのフィールドがデータとして宣言され、呼び出しごとに検証されます。未知のフィールドは「もしかして」付きで即エラーになり、エディタ補完も同じ一覧から生成されます。',
      },
      {
        title: '正直なライフサイクル',
        body: '各フックには LIVE か declarable かが明記されています。ネイティブイベントがまだ存在しないフックはその旨を書いてあるので、動かないコードを書かずに済みます。',
      },
    ],
  },
} as const;

const sample = `local pal = Pal{
    id          = "example:Boss",
    name        = "Boss Pal",
    description = "Greets you, loudly.",
    mesh        = Mesh{
        id    = "example:boss_body",
        model = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal",
    },
    events = {
        onSpawned = function(pal, ctx)
            pal:renderOn(ctx.actor)
            Audio.get("AKE_BGM_Title"):play()
        end,
    },
}

pal:spawn(Player.coordinate())`;

export default async function Home({ params }: { params: Promise<{ lang: string }> }) {
  const { lang } = await params;
  const t = lang === 'ja' ? copy.ja : copy.en;

  return (
    <main className="mx-auto flex w-full max-w-5xl flex-1 flex-col gap-16 px-4 py-16 md:py-24">
      <section className="flex flex-col items-start gap-6">
        <h1 className="text-4xl font-bold tracking-tight md:text-6xl">{appName}</h1>
        <p className="text-xl text-fd-muted-foreground md:text-2xl">{t.tagline}</p>
        <p className="max-w-3xl text-fd-muted-foreground">{t.lead}</p>
        <div className="flex flex-wrap gap-3">
          <Link
            href={`/${lang}/docs`}
            className="rounded-lg bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground transition-opacity hover:opacity-90"
          >
            {t.start}
          </Link>
          <Link
            href={`/${lang}/docs/api/pal`}
            className="rounded-lg border px-5 py-2.5 font-medium transition-colors hover:bg-fd-accent"
          >
            {t.reference}
          </Link>
          <a
            href={githubUrl}
            rel="noreferrer noopener"
            target="_blank"
            className="rounded-lg border px-5 py-2.5 font-medium transition-colors hover:bg-fd-accent"
          >
            {t.github}
          </a>
        </div>
      </section>

      <section className="grid gap-6 md:grid-cols-3">
        {t.features.map((f) => (
          <div key={f.title} className="rounded-xl border bg-fd-card p-5">
            <h2 className="mb-2 font-semibold">{f.title}</h2>
            <p className="text-sm text-fd-muted-foreground">{f.body}</p>
          </div>
        ))}
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-lg font-semibold">{t.exampleTitle}</h2>
        <pre className="overflow-x-auto rounded-xl border bg-fd-card p-5 text-sm leading-relaxed">
          <code>{sample}</code>
        </pre>
      </section>
    </main>
  );
}
