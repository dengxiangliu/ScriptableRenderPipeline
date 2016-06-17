using System;
using System.Collections.Generic;
using System.Reflection;
using UnityEngine;
using UnityEditor.Experimental;
using UnityEditor.Experimental.Graph;
using Object = UnityEngine.Object;


namespace UnityEditor.Experimental
{
    public class EditorKeyboardControl : IManipulate
    {
        VFXEdCanvas m_canvas;


        internal EditorKeyboardControl(VFXEdCanvas canvas)
        {
            m_canvas = canvas;
        }

        public void AttachTo(CanvasElement e)
        {
            e.KeyDown += OnCanvasKeyDown;
            SceneView.onSceneGUIDelegate += OnSceneGUIKeyDown;
        }

        public void OnSceneGUIKeyDown(SceneView sceneview)
        {
            Event e = Event.current;
            if(e.type == EventType.keyDown)
                    OnKeyDown(e);
        }

        private bool OnCanvasKeyDown(CanvasElement element, Event e, Canvas2D parent)
        {
            return OnKeyDown(e);
        }

        private bool OnKeyDown(Event e)
        { 
            if (e.type == EventType.used)
                return false;


            bool needRefresh = false;

            var component = VFXEditor.component;
            switch(e.keyCode)
            {
                case KeyCode.Alpha1: if (component == null) break; component.playRate = 0.01f; needRefresh = true; break;
                case KeyCode.Alpha2: if (component == null) break; component.playRate = 0.1f; needRefresh = true; break;
                case KeyCode.Alpha3: if (component == null) break; component.playRate = 0.25f; needRefresh = true; break;
                case KeyCode.Alpha4: if (component == null) break; component.playRate = 0.5f; needRefresh = true; break;
                case KeyCode.Alpha5: if (component == null) break; component.playRate = 1.0f; needRefresh = true; break;
                case KeyCode.Alpha6: if (component == null) break; component.playRate = 2.0f; needRefresh = true; break;
                case KeyCode.Alpha7: if (component == null) break; component.playRate = 8.0f; needRefresh = true; break;
                case KeyCode.L:
                    if(m_canvas.selection.Count > 0)
                    {
                        List<VFXSystemModel> modelsToLayout = new List<VFXSystemModel>(); 
                        foreach(CanvasElement selected in m_canvas.selection)
                        {
                            if(selected is VFXEdContextNode)
                            {
                                VFXEdContextNode node = (selected as VFXEdContextNode);
                                if (!modelsToLayout.Contains(node.Model.GetOwner()))
                                    modelsToLayout.Add(node.Model.GetOwner());
                            }
                        }

                        foreach(VFXSystemModel model in modelsToLayout)
                            VFXEdLayoutUtility.LayoutSystem(model, (VFXEdDataSource)m_canvas.dataSource);
                    }
                    m_canvas.Repaint();
                    break;
                case KeyCode.Space: VFXEditor.ForeachComponents(c => c.Reinit()); needRefresh = true; break;
                case KeyCode.P:
                    if (component != null)
                    {
                        component.pause = true;
                        component.AdvanceOneFrame();
                    }
                    break;
                default:
                    break;
            }

            if (needRefresh)
            {
                e.Use();
            }

            return needRefresh;
        }

        public bool GetCaps(ManipulatorCapability cap)
        {
            return false;
        }
    }
}
