defmodule SpecLint.BuildRecord.Capture do
  @moduledoc false

  alias Mix.Sync.PubSub

  # Mix's built-in Elixir and Erlang compilers publish the actual modules
  # they compiled. A barrier on the same channel drains these asynchronous
  # events before the caller records artifacts. Other OS processes cannot
  # supply evidence for this build.
  @spec start(module()) :: {pid(), String.t(), String.t()}
  def start(pubsub \\ PubSub) do
    unless Code.ensure_loaded?(pubsub) and function_exported?(pubsub, :subscribe, 1) and
             function_exported?(pubsub, :broadcast, 2) do
      Mix.raise("compiler artifact evidence API is unavailable: #{inspect(pubsub)}",
        exit_status: 2
      )
    end

    owner = self()
    key = Mix.Project.build_path()
    token = Base.encode16(:crypto.strong_rand_bytes(16))

    pid =
      spawn_link(fn ->
        try do
          case pubsub.subscribe(key) do
            :ok ->
              send(owner, {token, :ok})
              collect(owner, token, System.pid(), %{})

            other ->
              send(owner, {token, {:error, "invalid compiler subscription: #{inspect(other)}"}})
          end
        rescue
          error -> send(owner, {token, {:error, Exception.message(error)}})
        catch
          kind, reason -> send(owner, {token, {:error, "#{kind}: #{inspect(reason)}"}})
        end
      end)

    receive do
      {^token, :ok} -> {pid, key, token}
      {^token, {:error, reason}} -> Mix.raise(reason, exit_status: 2)
    end
  end

  @spec finish({pid(), String.t(), String.t()}) :: %{atom() => MapSet.t()}
  def finish({_pid, key, token}) do
    PubSub.broadcast(key, {:spec_lint_build_barrier, token})

    receive do
      {^token, {:error, reason}} ->
        Mix.raise("cannot collect compiler artifact evidence: #{reason}", exit_status: 2)

      {^token, modules} ->
        modules
    after
      30_000 -> Mix.raise("timed out collecting compiler artifact evidence", exit_status: 2)
    end
  end

  @spec stop({pid(), String.t(), String.t()}) :: true
  def stop({pid, _key, _token}) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
  end

  defp collect(owner, token, os_pid, modules) do
    receive do
      {:modules_compiled, %{os_pid: ^os_pid, app: app, modules_diff: diff}} ->
        compiled = MapSet.new(diff.added ++ diff.changed)
        modules = Map.update(modules, app, compiled, &MapSet.union(&1, compiled))
        collect(owner, token, os_pid, modules)

      {:spec_lint_build_barrier, ^token} ->
        send(owner, {token, modules})

      _other ->
        collect(owner, token, os_pid, modules)
    end
  end
end
