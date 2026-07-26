import Link from 'next/link';
import { appName, githubUrl } from '@/lib/shared';
import { i18n } from '@/lib/i18n';

export function generateStaticParams() {
  return i18n.languages.map((lang) => ({ lang }));
}

const copy = {
  en: {
    tagline: 'Add your own content to Palworld',
    lead: 'PalForge is a base mod that lets anyone add their own buildings, music, effects, pals, items, player behaviour, skills and menus to Palworld — or build entirely new content of their own — and see it in the game straight away. You describe what you want in a short text file, and PalForge puts it in the world.',
    start: 'Get started',
    reference: 'API reference',
    github: 'View on GitHub',
    exampleTitle: 'One definition, start to finish',
    features: [
      {
        title: 'Eight things you can make',
        body: 'Buildings, items, pals, skills, effects, sounds, models and menus. Each one is written the same way, so once you have made one you can make any of them.',
      },
      {
        title: 'Mistakes are caught as you type',
        body: 'Your editor completes every field and explains what it does. Misspell one and you get an error that tells you the name you meant, instead of something silently not working.',
      },
      {
        title: 'You are told what works',
        body: 'Every place your code can run is marked with whether the game actually triggers it yet. You will not spend an evening on a handler that was never going to fire.',
      },
    ],
  },
  ja: {
    tagline: 'パルワールドに自分のコンテンツを追加する',
    lead: 'PalForge は、だれでも建物・音楽・エフェクト・パル・アイテム・プレイヤーの挙動・スキル・UI を自由に追加できる（あるいはまったく新しいコンテンツを作れる）、パルワールドの基幹 MOD です。短いテキストファイルに「こうしたい」と書くだけで、それがゲームの中に現れます。',
    start: 'はじめる',
    reference: 'API リファレンス',
    github: 'GitHub で見る',
    exampleTitle: '定義から実行まで',
    features: [
      {
        title: '作れるもの 8 種類',
        body: '建物・アイテム・パル・スキル・効果・サウンド・モデル・メニュー。どれも同じ書き方なので、ひとつ作れれば残りも作れます。',
      },
      {
        title: '書きながら間違いに気づける',
        body: 'エディタが項目名と意味を補完します。名前を間違えると「もしかして」付きでその場でエラーになるので、黙って動かないということがありません。',
      },
      {
        title: '動くかどうかが書いてある',
        body: '処理を差し込める場所ごとに、ゲームが実際にそこを呼ぶかどうかが明記されています。呼ばれないと分かっている場所に一晩かけずに済みます。',
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
