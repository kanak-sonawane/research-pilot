import ResearchForm from "@/components/ResearchForm";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-6 p-6">
      <h1 className="text-2xl font-semibold">Research Pilot</h1>
      <ResearchForm />
    </main>
  );
}
