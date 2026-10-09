"""Hermetic actuation tests: fake tmux, systemctl, authority and model only."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class ActuationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.bin=self.root/'bin'; self.bin.mkdir()
        self.log=self.root/'calls'; self.home=self.root/'home'; self.home.mkdir()
        self.env=dict(os.environ, HOME=str(self.home), PATH=str(self.bin)+':/usr/bin:/bin',
                      CRSS_HOME=str(self.root/'no-overlay'), CRSS_SESSION_PREFIX='test',
                      CRSS_SESSIONS_DIR=str(self.root/'sessions'), CRSS_WORKSPACE=str(self.root/'workspace'),
                      NEW_SESSION_MIN_AVAIL_MB='0', CALLS=str(self.log),
                      AGENT_HOST_ADMISSION_CLI=str(self.bin/'authority.py'),
                      AGENT_HOST_ADMISSION_DB=str(self.root/'db'), AGENT_HOST_ADMISSION_EVIDENCE=str(self.root/'e'))
        self.stub('systemctl','echo systemctl >> "$CALLS"; exit 0')
        self.stub('tmux', '''case "$1" in
has-session) exit 1;;
ls) exit 0;;
*) echo "tmux $*" >> "$CALLS";;
esac''')
        self.stub('sleep','exit 0')
        self.stub('fake-model','echo model >> "$CALLS"; exit 0')
        (self.bin/'authority.py').write_text('import sys\nprint(\'{"decision":"DENY","reason":"paused"}\')\nsys.exit(2)\n')
        self.env['CRSS_CLAUDE_BIN']=str(self.bin/'fake-model')
        self.env['CRSS_CODEX_BIN']=str(self.bin/'fake-model')
    def stub(self,name,text):
        p=self.bin/name; p.write_text('#!/bin/bash\n'+text+'\n'); p.chmod(0o755)
    def run_shell(self,text,**env):
        return subprocess.run(['bash','-c',text],env=dict(self.env,**env),cwd=self.root,capture_output=True,text=True,timeout=20)
    def calls(self): return self.log.read_text() if self.log.exists() else ''
    def generated(self, backend="claude"):
        p=subprocess.run(['bash',str(ROOT/'scripts/new-session.sh'),'fake','sessions','--backend',backend],env=self.env,cwd=self.root,capture_output=True,text=True,timeout=20)
        files=list((self.home/'.local/bin').glob('*-start.sh'))
        self.assertEqual(len(files),1,p.stderr+p.stdout)
        self.log.unlink(missing_ok=True)
        return files[0].read_text()
    def test_generated_restart_denies_after_manual_first_launch(self):
        script=self.generated()
        # Execute the actual serialized payload produced by the generator.
        start=script.index("'LOG_FILE=")+1; end=script.index("done'",start)+4
        payload=script[start:end]
        p=self.run_shell(payload)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.calls().count('model\n'),1)
        self.assertIn('autonomous admission denied',p.stdout)
        again=self.run_shell(payload)
        self.assertEqual(again.returncode,0,again.stderr)
        self.assertEqual(self.calls().count('model\n'),1)  # service/process restart cannot bypass
    def test_operator_manual_resume_intent_is_consumed_once(self):
        script=self.generated()
        start=script.index("'LOG_FILE=")+1; end=script.index("done'",start)+4
        payload=script[start:end]
        pin=Path(re.search(r'^RESUME_PIN="([^"]+)"',payload,re.M).group(1))
        marker=Path(re.search(r'^MANUAL_LAUNCH="([^"]+)"',payload,re.M).group(1))
        pin.parent.mkdir(parents=True,exist_ok=True)
        pin.write_text('explicit-uuid'); marker.write_text('explicit-uuid')
        # Previously launched session, so an automatic service restart is denied.
        remote=re.search(r'^REMOTE_NAME=(.+)$',script,re.M).group(1)
        (self.root/('.sessions-init-'+remote)).touch()
        p=self.run_shell(payload)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.calls().count('model\n'),1)
        self.assertFalse(marker.exists())
        self.run_shell(payload)
        self.assertEqual(self.calls().count('model\n'),1)
    def test_generated_codex_restart_denies_after_initial_fail_closed(self):
        script=self.generated('codex')
        start=script.index("CODEX_LOOP_EOF'\n")+len("CODEX_LOOP_EOF'\n")
        end=script.index('\nCODEX_LOOP_EOF',start)
        # Missing native pin helper fails closed on the manual first pass; the
        # next automatic pass must consult admission before doing any work.
        p=self.run_shell(script[start:end])
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertNotIn('model',self.calls())
        self.assertIn('autonomous admission denied',p.stdout)
    def test_generated_autonomous_first_pass_denies(self):
        script=self.generated(); start=script.index("'LOG_FILE=")+1; end=script.index("done'",start)+4
        # Generated first-pass predicate comes from caller provenance; exercise
        # the generator with its actual autonomous value through the heredoc.
        source=(ROOT/'scripts/new-session.sh').read_text()
        a=source.index("tmux send-keys -t \"${SESSION}\" 'LOG_FILE=")
        b=source.index('\nSCRIPT_EOF',a)
        heredoc=source[a:b]
        p=self.run_shell('''SESSION=test; REMOTE_NAME=test; MODEL=fake; CLAUDE_EXTRA_FLAGS=; CRSS_CLAUDE_HOME=/tmp
ADMISSION_HELPER="'''+str(ROOT/'scripts/autonomous-admission.sh')+'''"; ADMISSION_SUBJECT=test
cat <<SCRIPT_EOF
'''+heredoc+'''\nSCRIPT_EOF
''',CRSS_AUTONOMOUS='1')
        self.assertEqual(p.returncode,0,p.stderr)
        generated=p.stdout; start=generated.index("'LOG_FILE=")+1; end=generated.index("done'",start)+4
        q=self.run_shell(generated[start:end]); self.assertEqual(q.returncode,0,q.stderr)
        self.assertNotIn('model',self.calls())
    def test_autonomous_new_session_denies_before_systemctl_or_paste(self):
        p=subprocess.run(['bash',str(ROOT/'scripts/new-session.sh'),'fake','sessions'],env=dict(self.env,CRSS_AUTONOMOUS='1'),cwd=self.root,capture_output=True,text=True,timeout=20)
        self.assertEqual(p.returncode,2,p.stderr+p.stdout)
        self.assertEqual(self.calls(),'')
        self.assertFalse(list((self.home/'.local/bin').glob('*-start.sh')))
    def test_autonomous_dry_run_preserves_read_only_preview(self):
        p=subprocess.run(['bash',str(ROOT/'scripts/new-session.sh'),'--dry-run','fake','sessions'],env=dict(self.env,CRSS_AUTONOMOUS='1'),cwd=self.root,capture_output=True,text=True,timeout=20)
        self.assertEqual(p.returncode,0,p.stderr); self.assertEqual(self.calls(),'')
    def test_paste_denies_zero_tmux_calls(self):
        source=(ROOT/'scripts/session-handoff.sh').read_text()
        helper=source[source.index('_crss_admit()'):source.index('# ── Host-local overlay')]
        function=source[source.index('_paste_and_wait()'):source.index('# _model_of')]
        p=self.run_shell(helper+'\n'+function+'\n_paste_and_wait fake frag message',CRSS_AUTONOMOUS='1')
        self.assertEqual(p.returncode,2,p.stderr); self.assertIn('admission-denied',p.stdout)
        self.assertEqual(self.calls(),'')
    def test_autonomous_resume_denies_before_control_commands(self):
        p=subprocess.run(['bash',str(ROOT/'scripts/session-resume.sh'),'fake'],env=dict(self.env,CRSS_AUTONOMOUS='1'),capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,2,p.stderr); self.assertEqual(self.calls(),'')
    def test_resume_admission_subject_is_session_name_not_a_leading_flag(self):
        # --uuid/--model may precede the positional session name (session-resume's own
        # parser accepts either order); the admission subject must still be the session,
        # never the literal flag token, or quota/admission tracking keys on the wrong subject.
        (self.bin/'authority.py').write_text(
            "import sys,os\n"
            "open(os.environ['CALLS'],'a').write('subject:'+sys.argv[3]+chr(10))\n"
            "print('{\"decision\":\"ALLOW\"}')\n"
            "sys.exit(0)\n")
        p=subprocess.run(['bash',str(ROOT/'scripts/session-resume.sh'),'--uuid',
                           '12345678-1234-1234-1234-123456789012','fake'],
                          env=dict(self.env,CRSS_AUTONOMOUS='1'),capture_output=True,text=True,timeout=10)
        self.assertIn('subject:fake',self.calls(),p.stderr+p.stdout)
    def test_compact_sweep_denies_before_handoff(self):
        source=(ROOT/'scripts/session-compact.sh').read_text()
        start=source.index('_do_compact()'); end=source.index('\n}\n',start)+3
        helper='''declare -A _COMPACT_ISSUED=(); _crss_admit() { return 2; }; _session_handoff() { echo paste >> "$CALLS"; }; MODE=sweep
'''
        p=self.run_shell(helper+source[start:end]+'\n_do_compact fake 1')
        self.assertNotEqual(p.returncode,0); self.assertIn('admission-denied',p.stdout); self.assertEqual(self.calls(),'')

    def test_denial_is_logged_to_starts_log(self):
        helper=str(ROOT/'scripts/autonomous-admission.sh'); log=self.home/'.sessions/session-starts.log'
        p=self.run_shell(f'bash {helper} launch subj-a')
        self.assertEqual(p.returncode,2); self.assertIn('DENY',p.stdout)
        self.assertRegex(log.read_text(),r'event=admission-denied action=launch subject=subj-a rc=2')
        q=self.run_shell(f'bash {helper} wake subj-b',AGENT_HOST_ADMISSION_CLI='')
        self.assertEqual(q.returncode,2); self.assertIn('authority unavailable',q.stderr)
        self.assertIn('action=wake subject=subj-b rc=2',log.read_text())
    def test_allow_writes_no_denial_line(self):
        (self.bin/'ok.py').write_text('import sys\nprint("{}")\n')
        helper=str(ROOT/'scripts/autonomous-admission.sh')
        p=self.run_shell(f'bash {helper} launch s',AGENT_HOST_ADMISSION_CLI=str(self.bin/'ok.py'))
        self.assertEqual(p.returncode,0); self.assertFalse((self.home/'.sessions/session-starts.log').exists())

    def test_invalid_admission_config_preserves_manual_launch_only(self):
        self.env['AGENT_HOST_ADMISSION_CLI']='/tmp/invalid authority.py'
        self.env['CRSS_ADMISSION_SUBJECT']="invalid subject"
        script=self.generated(); start=script.index("'LOG_FILE=")+1; end=script.index("done'",start)+4
        p=self.run_shell(script[start:end])
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.calls().count('model\n'),1)
        self.assertIn('autonomous admission denied',p.stdout)
        self.run_shell(script[start:end])
        self.assertEqual(self.calls().count('model\n'),1)
    def test_invalid_admission_config_still_denies_autonomous_launch(self):
        self.env['AGENT_HOST_ADMISSION_CLI']='/tmp/invalid authority.py'
        p=subprocess.run(['bash',str(ROOT/'scripts/new-session.sh'),'fake','sessions'],env=dict(self.env,CRSS_AUTONOMOUS='1'),cwd=self.root,capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,2,p.stderr); self.assertEqual(self.calls(),'')
    def real_authority(self):
        import json,sqlite3,time
        authority=os.environ.get('QUOTA_TEST_AUTHORITY')
        if not authority:
            self.skipTest('cross-repo fixture requires QUOTA_TEST_AUTHORITY')
        self.env['AGENT_HOST_ADMISSION_CLI']=authority
        self.env['CRSS_ADMISSION_SUBJECT']='bounded-session'
        with sqlite3.connect(self.env['AGENT_HOST_ADMISSION_DB']) as db:
            db.execute('CREATE TABLE jobs(job_id TEXT)')
        stamp=time.time()
        Path(self.env['AGENT_HOST_ADMISSION_EVIDENCE']).write_text(json.dumps(dict(schema='autonomous-admission/v1',evidence_id='finite',subject='bounded-session',actions=['launch','wake','restart'],wall_seconds=1,available_calls=3,observed_at=stamp-1,expires_at=stamp+60,context_tokens=1000,cache_warm=False,idle_seconds=0,children=0,compactions=0)))
    def assert_cooperative_stop(self):
        import sqlite3
        with sqlite3.connect(self.env['AGENT_HOST_ADMISSION_DB']) as db:
            self.assertEqual(db.execute('SELECT reason FROM autonomous_pause').fetchone()[0],'unsupported_interactive_tty')
            self.assertEqual(db.execute('SELECT count(*) FROM autonomous_grants').fetchone()[0],0)
            self.assertEqual(db.execute("SELECT count(*) FROM autonomous_admission_audit WHERE action='reset'").fetchone()[0],0)
        self.assertFalse(list(self.home.rglob('*.manual-launch')))
    def test_real_finite_grant_cannot_open_interactive_preflight(self):
        self.real_authority()
        p=subprocess.run(['bash',str(ROOT/'scripts/new-session.sh'),'fake','sessions'],env=dict(self.env,CRSS_AUTONOMOUS='1'),cwd=self.root,capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,2,p.stderr); self.assertEqual(self.calls(),'')
        self.assert_cooperative_stop()
    def test_real_generated_loop_manual_tty_then_persistent_restart_stop(self):
        import pty
        self.real_authority()
        self.stub('fake-model','[ -t 0 ] || exit 99; echo manual-tty >> "$CALLS"; exit 0')
        script=self.generated(); start=script.index("'LOG_FILE=")+1; end=script.index("done'",start)+4
        master,slave=pty.openpty()
        try:
            p=subprocess.run(['bash','-c',script[start:end]],stdin=slave,env=self.env,cwd=self.root,capture_output=True,text=True,timeout=10)
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertEqual(self.calls().count('manual-tty'),1)
            self.assertIn('autonomous admission denied',p.stdout)
            self.assert_cooperative_stop()
            again=self.run_shell(script[start:end])
            self.assertEqual(again.returncode,0,again.stderr)
            self.assertEqual(self.calls().count('manual-tty'),1)
            self.assert_cooperative_stop()
        finally:
            os.close(master); os.close(slave)
    def test_real_generated_codex_reexecution_stops_without_reset(self):
        self.real_authority(); script=self.generated('codex')
        start=script.index("CODEX_LOOP_EOF'\n")+len("CODEX_LOOP_EOF'\n")
        end=script.index('\nCODEX_LOOP_EOF',start)
        p=self.run_shell(script[start:end]); self.assertEqual(p.returncode,0,p.stderr)
        self.assertNotIn('model',self.calls()); self.assert_cooperative_stop()
        self.run_shell(script[start:end]); self.assert_cooperative_stop()


if __name__=='__main__': unittest.main(verbosity=2)
