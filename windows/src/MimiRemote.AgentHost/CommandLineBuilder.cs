using System.Text;

namespace MimiRemote.AgentHost;

/// <summary>
/// 按 <c>CommandLineToArgvW</c> 的反向规则拼命令行：目标程序随后会用同一套规则
/// 还原参数，所以引号和反斜杠必须成对加倍或转义，否则路径里的空格和中文会错位。
/// </summary>
internal static class CommandLineBuilder
{
    internal static string Build(IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);

        var builder = new StringBuilder();
        for (var index = 0; index < arguments.Count; index++)
        {
            if (index > 0)
            {
                builder.Append(' ');
            }

            AppendArgument(builder, arguments[index]);
        }

        return builder.ToString();
    }

    internal static void AppendArgument(StringBuilder builder, string argument)
    {
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentNullException.ThrowIfNull(argument);

        // 空参数如果原样输出会在解析时直接消失，必须显式写成一对引号。
        if (argument.Length == 0)
        {
            builder.Append("\"\"");
            return;
        }

        if (argument.AsSpan().IndexOfAny(' ', '\t', '"') < 0)
        {
            builder.Append(argument);
            return;
        }

        builder.Append('"');

        for (var index = 0; index < argument.Length; index++)
        {
            var backslashes = 0;
            while (index < argument.Length && argument[index] == '\\')
            {
                backslashes++;
                index++;
            }

            if (index == argument.Length)
            {
                // 结尾的反斜杠会转义收尾引号，所以必须加倍。
                builder.Append('\\', backslashes * 2);
                break;
            }

            if (argument[index] == '"')
            {
                builder.Append('\\', (backslashes * 2) + 1);
                builder.Append('"');
                continue;
            }

            builder.Append('\\', backslashes);
            builder.Append(argument[index]);
        }

        builder.Append('"');
    }
}
