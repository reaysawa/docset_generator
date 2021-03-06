defmodule DocsetGenerator.Indexer do
  alias DocsetGenerator.{
    DirectoryCrawler,
    WorkerParser,
    Packager,
    ViaTupleRegistry
  }

  use Agent

  @worker_pool_amount 4
  @worker_supervisor_name :worker_supervisor

  def start_link(packager) do
    agent = Agent.start_link(fn -> init(packager) end, name: via_tuple())

    # kick off some work right away, after the supervision tree has been started
    DirectoryCrawler.get_next_n(@worker_pool_amount)
    |> Enum.map(&new_filepath(&1))

    agent
  end

  def via_tuple(), do: {:via, ViaTupleRegistry, {__MODULE__}}

  defp init(%Packager{:doc_directory => root, :parser => parser} = packager) do
    children = [
      {DirectoryCrawler, [root]},
      {Task.Supervisor, name: @worker_supervisor_name}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)

    %{
      :entries => [],
      :errors => [],
      :workers => [],
      :filepath_buffer => [],
      :directory_crawling_done => false,
      :packager => packager,
      :parser_functions => parser.matcher_functions()
    }
  end

  def new_entry(entry) do
    Agent.update(via_tuple(), fn state ->
      Map.update!(state, :entries, &[entry | &1])
    end)
  end

  def new_filepath(:ok) do
    Agent.update(via_tuple(), fn state ->
      Map.update!(
        state,
        :directory_crawling_done,
        fn _ -> true end
      )
    end)
  end

  def new_filepath(filepath) do
    Agent.update(via_tuple(), fn state ->
      schedule_work(state, filepath)
    end)
  end

  @doc """
  Informs to the indexer that a task has been done, thus it can remove the task pid from the list of workers to free up space for a waiting filepath from the buffer.
  """
  def task_done(done_task_pid) do
    Agent.update(via_tuple(), fn state ->
      schedule_work(
        Map.update!(
          state,
          :workers,
          &Enum.reject(&1, fn {worker_pid, _} ->
            worker_pid == done_task_pid
          end)
        )
      )
    end)
  end

  def report_error(error, filepath) do
    Agent.update(via_tuple(), fn state ->
      Map.update!(
        state,
        :errors,
        &[%{:error => error, :filepath => filepath} | &1]
      )
    end)
  end

  # Waits for the workers to finish and calls the action build the docset with all the accumulated entries.
  defp indexing_done(final_state) do
    final_state
    |> DocsetGenerator.build_docset()
  end

  defp spawn_single_worker(filepath, parser_functions) do
    {:ok, pid} =
      Task.Supervisor.start_child(
        @worker_supervisor_name,
        fn -> WorkerParser.start_link(filepath, parser_functions) end
      )

    pid
  end

  # Attempts to use any buffered filepath discovered from the crawler.
  # - Updates the state by scheduling work to the first buffered filepath if it's there.
  # - Returns the state if there's no filepath in the buffer to be processed.
  defp schedule_work(next_state) do
    if Enum.empty?(next_state[:filepath_buffer]) &&
         next_state[:directory_crawling_done] do
      indexing_done(next_state)
    else
      [next_filepath | remaining] = next_state[:filepath_buffer]

      schedule_work(
        next_state
        |> Map.update!(:filepath_buffer, fn _ -> remaining or [] end),
        next_filepath
      )
    end
  end

  # Attempts to schedule work for a new filepath if the pool is open.
  # Otherwise, pushes the filepath into the buffer for further processing.
  defp schedule_work(next_state, filepath) do
    if length(next_state[:workers]) < @worker_pool_amount do
      Map.update!(
        next_state,
        :workers,
        &[
          spawn_single_worker(filepath, next_state[:parser_functions]) | &1
        ]
      )
    else
      Map.update!(next_state, :filepath_buffer, &[filepath | &1])
    end
  end
end
